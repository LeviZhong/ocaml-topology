open Packet

type node = Switch | Host | Middlebox

type attributes = {
  node_type : node
  ; name : string
  ; ip : nwAddr
  ; mac : dlAddr
  ; id : int64
}
