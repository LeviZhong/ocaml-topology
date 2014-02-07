open Graph
open Sexplib.Conv
open Topology

type topoType =
  | Persistent
  | Imperative
  | PersistentTbl
  | ImperativeTbl

let ttype = ref Persistent
let infname = ref ""
let outfname = ref ""

module CachedNode = struct

  type t = { mutable hash : int option; data : Node.t }

  let hash (ch: t) : int = match ch with
    | { hash = Some n; _ } -> n
    | { hash = None; data = d } ->
      let n = Hashtbl.hash d in
      ch.hash <- Some n;
      n

  let equal (n1: t) (n2: t) = match n1,n2 with
    | { hash = Some n1'; _ }, { hash = Some n2'; _ } -> n1' = n2'
    | { hash = _; data = d1 }, { hash = _; data = d2 } -> d1 = d2

  let compare (n1: t) (n2: t) = match n1,n2 with
    | { hash = Some n1'; _ }, { hash = Some n2'; _ } -> Pervasives.compare n1' n2'
    | { hash = _; data = d1 }, { hash = _; data = d2 } -> Pervasives.compare d1 d2
end


module CachedEdge = struct

  type v = CachedNode.t
  type t = {
    srcport : portId;
    dstport : portId;
    cost : int64;
    capacity : int64;
  }

  type e = v * t * v
  let compare = Pervasives.compare
  let default = {
    srcport = 0L;
    dstport = 0L;
    cost = 1L;
    capacity = Int64.max_int
  }

end

module PathKey = struct
  type t = CachedNode.t * CachedNode.t
  let equal (n1,n2) (n1',n2') =
    CachedNode.equal n1 n1' && CachedNode.equal n2 n2'

  let hash = Hashtbl.hash
end

module NodeTbl = Hashtbl.Make(CachedNode)
module PathTbl = Hashtbl.Make(PathKey)

module type CACHED = sig
  module G : Sig.G with type V.t = CachedNode.t
  val make_from_topo : Topology.t -> G.t
end

module Make(C:CACHED) = struct
  include C

  let shortest_path_tbl t src dst len path_tbl =
    let start = Unix.gettimeofday () in
    let distances = NodeTbl.create len in
    let visited = NodeTbl.create len in
    let queue = Core.Std.Heap.create (fun (v,d) (v,d') -> compare d d') () in

    let init = Unix.gettimeofday () in
    (* let rec mk_path current = *)
    (*   if current = src then [src] else *)
    (*     let prev = NodeTbl.find previous current in *)
    (*     prev::(mk_path prev) in *)

    let rec loop current =
      if current = dst then [current]
      else
        try PathTbl.find path_tbl (current,dst)
        with Not_found -> begin
          NodeTbl.replace visited current 0;
          G.iter_succ (fun next ->
            if NodeTbl.mem visited next then () else
            (* Assumes that all weights are 1 *)
            let path = (loop next) in
            let next_dist = List.length path in
            Core.Std.Heap.add queue (path,next_dist)
          ) t current;
          match Core.Std.Heap.pop queue with
            | Some (p,d) -> begin
              PathTbl.replace path_tbl (current,dst) p;
              current::p end
            | None -> [current]
        end in

    let _ = loop src in
    let find = Unix.gettimeofday () in
    (init -. start, find -. init)

  (* let shortest_path t src dst len = *)
  (*   let start = Unix.gettimeofday () in *)
  (*   let distances = NodeTbl.create len in *)
  (*   let visited = NodeTbl.create len in *)
  (*   let previous =  NodeTbl.create len in *)
  (*   let queue = Core.Std.Heap.create (fun (v,d) (v,d') -> compare d d') () in *)
  (*   Core.Std.Heap.add queue (src,0); *)

  (*   let init = Unix.gettimeofday () in *)
  (*   let rec mk_path current = *)
  (*     if current = src then [src] else *)
  (*       let prev = NodeTbl.find previous current in *)
  (*       prev::(mk_path prev) in *)

  (*   let rec loop (current,distance) = *)
  (*     if current = dst then () *)
  (*     else begin *)
  (*       G.iter_succ (fun next -> *)
  (*         if NodeTbl.mem visited next then () *)
  (*         else *)
  (*           let next_dist = distance + 1 in *)
  (*           let better = *)
  (*             try next_dist < (NodeTbl.find distances next) with Not_found -> true *)
  (*           in *)
  (*           if better then begin *)
  (*             NodeTbl.replace distances next next_dist; *)
  (*             NodeTbl.replace previous next current; *)
  (*             Core.Std.Heap.add queue (next,next_dist) end *)
  (*       ) t current; *)
  (*       NodeTbl.replace visited current 0; *)
  (*       loop (Core.Std.Heap.pop_exn queue) end in *)

  (*   loop (Core.Std.Heap.pop_exn queue); *)
  (*   let find = Unix.gettimeofday () in *)
  (*   let _ = mk_path dst in *)
  (*   let gather = Unix.gettimeofday () in *)
  (*   (init -. start, find -. init, gather -. find) *)

module Weight = struct
  open CachedEdge
  type t = Int64.t
  type label = G.E.label
  let weight l = 1L
  let compare = Int64.compare
  let add = Int64.add
  let zero = Int64.zero
end
  module Dij = Path.Dijkstra(G)(Weight)
  module BF = Path.BellmanFord(G)(Weight)

  let floyd_warshall (g:G.t) : ((G.V.t * G.V.t) * G.V.t list) list =
    let add_opt o1 o2 =
      match o1, o2 with
        | Some n1, Some n2 -> Some (Int64.add n1 n2)
        | _ -> None in
    let lt_opt o1 o2 =
      match o1, o2 with
        | Some n1, Some n2 -> n1 < n2
        | Some _, None -> true
        | None, Some _ -> false
        | None, None -> false in
    let get_vertices (g:G.t) : (G.V.t list) =
        G.fold_vertex (fun v acc -> v::acc) g [] in
    let make_matrix (g:G.t) =
      let n = G.nb_vertex g in

      let nodes = Array.of_list (get_vertices g) in
      Array.init n
        (fun i -> Array.init n
          (fun j -> if i = j then (Some 0L, [nodes.(i)])
            else
              try
                let l = G.find_edge g nodes.(i) nodes.(j) in
                (Some 1L, [nodes.(i); nodes.(j)])
            with Not_found ->
              (None,[]))) in
    let matrix = make_matrix g in
    let n = G.nb_vertex g in
    let dist i j = fst (matrix.(i).(j)) in
    let path i j = snd (matrix.(i).(j)) in
    for k = 0 to n - 1 do
      for i = 0 to n - 1 do
        for j = 0 to n - 1 do
          let dist_ikj = add_opt (dist i k) (dist k j) in
          if lt_opt dist_ikj (dist i j) then
            matrix.(i).(j) <- (dist_ikj, path i k @ List.tl (path k j))
        done
      done
    done;
    let paths = ref [] in
    let vxs = Array.of_list (get_vertices g) in
    Array.iteri (fun i array ->
      Array.iteri (fun j elt ->
        let (_, p) = elt in
        paths := ((vxs.(i),vxs.(j)),p) :: !paths) array;) matrix;
    !paths

  module H = Hashtbl.Make(G.V)
  exception NegativeCycle of G.E.t list
  let all_shortest_paths g vs =
    let open G.E in
    let dist = H.create 97 in
    let prev = H.create 97 in
    H.add dist vs Weight.zero;
    let admissible = H.create 97 in
    let build_cycle_from x0 =
      let rec traverse_parent x ret =
	let e = H.find admissible x in
	let s = src e in
	if G.V.equal s x0 then e :: ret else traverse_parent s (e :: ret)
      in
      traverse_parent x0 []
    in
    let find_cycle x0 =
      let visited = H.create 97 in
      let rec visit x =
	if H.mem visited x then
	  build_cycle_from x
	else begin
	  H.add visited x ();
	  let e = H.find admissible x in
	  visit (src e)
	end
      in
      visit x0
    in
    let rec relax i =
      let update = G.fold_edges_e
        (fun e x ->
          let ev1 = src e in
          let ev2 = dst e in
          try begin
            let dev1 = H.find dist ev1 in
            let dev2 = Weight.add dev1 (Weight.weight (label e)) in
            let improvement =
              try Weight.compare dev2 (H.find dist ev2) < 0
              with Not_found -> true
            in
            if improvement then begin
              H.replace prev ev2 ev1;
              H.replace dist ev2 dev2;
	          H.replace admissible ev2 e;
              Some ev2
            end else x
          end with Not_found -> x) g None in
      match update with
      | Some x ->
        if i == G.nb_vertex g then raise (NegativeCycle (find_cycle x))
        else relax (i + 1)
      | None -> dist,prev
    in
    relax 0

  let all_pairs (t:G.t) : (float * float * float * float) =
    let open CachedNode in
    let hosts = G.fold_vertex (fun v acc -> match v with
      | {hash =  _; data = Node.Host(_)} -> v::acc
      | _ -> acc
    ) t [] in
    let times = ref 0.0 in
    let itimes = ref 0.0 in
    let ftimes = ref 0.0 in
    let gtimes = ref 0.0 in
    let vert_num = G.nb_vertex t in
    Printf.printf "Number of vertices:%d\n%!" vert_num;
    let start = Unix.gettimeofday () in
    List.iter (fun h ->
      let each_start = Unix.gettimeofday () in
      let _ = all_shortest_paths t h in
      let each_stop = Unix.gettimeofday () in
                           (* Printf.printf "%f\n%!" (each_stop -.each_start); *)
                           ()) hosts;

    (* List.iter (fun src -> List.iter (fun dst -> *)
    (*   if not (src = dst) then *)
    (*     let each_start = Unix.gettimeofday () in *)
    (*     let _ = Dij.shortest_path t src dst in *)
    (*     (\* let i,f,g = shortest_path t src dst vert_num in *\) *)
    (*     let each_stop = Unix.gettimeofday () in *)
    (*     Printf.printf "Iteration:%f\n%!" (each_stop -. each_start); *)
    (*     (\* itimes := !itimes +. i; *\) *)
    (*     (\* ftimes := !ftimes +. f; *\) *)
    (*     (\* gtimes := !gtimes +. g; *\) *)
    (*     times := !times +. (each_stop -. each_start) *)
    (* ) hosts ) hosts; *)
    let stop = Unix.gettimeofday () in
    (stop -. start, !itimes, !ftimes, !gtimes)

  let all_pairs_tbl (t:G.t) : (float * float * float) =
    let open CachedNode in
    let hosts = G.fold_vertex (fun v acc -> match v with
      | {hash =  _; data = Node.Host(_)} -> v::acc
      | _ -> acc
    ) t [] in
    let times = ref 0.0 in
    let itimes = ref 0.0 in
    let ftimes = ref 0.0 in
    let vert_num = G.nb_vertex t in
    let tbl = PathTbl.create (vert_num * vert_num) in
    let start = Unix.gettimeofday () in
    List.iter (fun src -> List.iter (fun dst ->
      if not (src = dst) then
        let each_start = Unix.gettimeofday () in
        let i,f = shortest_path_tbl t src dst vert_num tbl in
        let each_stop = Unix.gettimeofday () in
        itimes := !itimes +. i;
        ftimes := !ftimes +. f;
        times := !times +. (each_stop -. each_start)
    ) hosts ) hosts;
    let stop = Unix.gettimeofday () in
    (stop -. start, !itimes, !ftimes)

end

module Persistent = Make(struct
  module G = Persistent.Digraph.ConcreteLabeled(CachedNode)(CachedEdge)

  let make_from_topo p =
    let g = G.empty in
    let open CachedNode in
    Topology.fold_edges_e (fun (s,l,d) g ->
      let s' = {hash = Some(Hashtbl.hash s); data = s} in
      let d' = {hash = Some(Hashtbl.hash d); data = d} in
      let open CachedEdge in
      let l' = {srcport = l.Link.srcport; dstport = l.Link.dstport;
                cost = l.Link.cost; capacity = l.Link.capacity} in
      G.add_edge_e g (s',l',d'))
      p g
end)

module Imperative = Make(struct
  module G = Imperative.Digraph.ConcreteLabeled(CachedNode)(CachedEdge)

  let make_from_topo p =
    let g = G.create ~size:(Topology.nb_edges p) () in
    let open CachedNode in
    Topology.iter_edges_e (fun (s,l,d) ->
      let s' = {hash = Some (Hashtbl.hash s); data = s} in
      let d' = {hash = Some (Hashtbl.hash d); data = d} in
      let open CachedEdge in
      let l' = {srcport = l.Link.srcport; dstport = l.Link.dstport;
                cost = l.Link.cost; capacity = l.Link.capacity} in
      G.add_edge_e g (s',l',d') ) p;
      g

end)

let arg_spec =
  [
    ("-p",
       Arg.Unit (fun () -> ttype := Persistent),
     "\tUse a persistent topology implementation")
    ; (
      "-i",
      Arg.Unit (fun () -> ttype := Imperative),
      "\tUse an imperative topology implementation")
    ; ("-pt",
       Arg.Unit (fun () -> ttype := PersistentTbl),
     "\tUse a persistent topology implementation with a memo table")
    ; (
      "-it",
      Arg.Unit (fun () -> ttype := ImperativeTbl),
      "\tUse an imperative topology implementation with a memo table")

    ; ("-o",
       Arg.String (fun s -> outfname := s ),
       "\tWrite topology to a file")
]

let usage = Printf.sprintf "usage: %s [--dot|--gml] filename -o filename [--dot|--mn]" Sys.argv.(0)


let _ =
  Arg.parse arg_spec (fun fn -> infname := fn) usage ;
  match !ttype with
    | Persistent ->
      Printf.printf "Running persistent version with cached node hashes\n%!";
      let g = from_dotfile !infname in
      let g' = Persistent.make_from_topo g in
      let total, i, f, g = Persistent.all_pairs g' in
      Printf.printf "All-pairs shortest path %f\n%!" total;
      Printf.printf "Init:%f Find:%f Gather:%f\n%!" i f g
    | Imperative ->
      Printf.printf "Running imperative version with cached node hashes\n%!";
      let g = from_dotfile !infname in
      let g' = Imperative.make_from_topo g in
      let total, i, f, g = Imperative.all_pairs g' in
      Printf.printf "All-pairs shortest path %f\n%!" total;
      Printf.printf "Init:%f Find:%f Gather:%f\n%!" i f g
    | PersistentTbl ->
      Printf.printf "Running persistent version with cached node hashes\n%!";
      let g = from_dotfile !infname in
      let g' = Persistent.make_from_topo g in
      let total, i, f = Persistent.all_pairs_tbl g' in
      Printf.printf "All-pairs shortest path %f\n%!" total;
      Printf.printf "Init:%f Find:%f\n%!" i f
    | ImperativeTbl ->
      Printf.printf "Running imperative version with cached node hashes\n%!";
      let g = from_dotfile !infname in
      let g' = Imperative.make_from_topo g in
      let total, i, f = Imperative.all_pairs_tbl g' in
      Printf.printf "All-pairs shortest path %f\n%!" total;
      Printf.printf "Init:%f Find:%f\n%!" i f
