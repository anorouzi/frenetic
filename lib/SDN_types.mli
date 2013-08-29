(** A uniform interface for programming switches that can use both OpenFlow 1.0
  and OpenFlow 1.3 as its back-end. *)

(** {1 OpenFlow Identifier Types}

  OpenFlow requires identifiers for switches, ports, transaction numbers, etc.
  The representation of these identifiers varies across different versions
  of OpenFlow, which is why they are abstract.
*)

type int8 = int
type int12 = int
type int16 = int
type int32 = Int32.t
type int64 = Int64.t
type int48 = Int64.t
type bytes = string

type switchId =
  | OF10SwitchId of OpenFlow0x01_Core.switchId
  | OF13SwitchId of OpenFlow0x04_Core.switchId

type portId =
  | OF10PortId of OpenFlow0x01_Core.portId
  | OF13PortId of OpenFlow0x04_Core.portId

type bufferId =
  | OF10BufferId of int32
  | OF13BufferId of OpenFlow0x04_Core.bufferId

exception Unsupported of string

(** {1 Packet Forwarding} *)

type port =
  | PhysicalPort of portId
  | AllPorts
  | Controller of int

type field =
  | InPort
  | EthType
  | EthSrc
  | EthDst
  | Vlan
  | VlanPcp
  | IPProto
  | IP4Src
  | IP4Dst
  | TCPSrcPort
  | TCPDstPort

type fieldVal = VInt.t

module FieldMap : Map.S
  with type key = field

(** WARNING: There are dependencies between different fields that must be met. *)
type pattern = fieldVal FieldMap.t


(** A high-level language, such as Frenetic, should support OpenFlow 1.0
  and also exploit OpenFlow 1.3 features when possible. For example,
  when two Frenetic actions are composed in parallel, they logically work
  on two copies of a packet. Certain kinds of parallel composition cannot
  be realized in OpenFlow 1.0, but they are trivial to implement with
  group tables in OpenFlow 1.3.

  Similarly, OpenFlow 1.3 can implement failover efficiently using fast-
  failover groups. But, in OpenFlow 1.0, we have to incur a round-trip
  to the controller.

  Instead of creating two different versions of the Frenetic compiler, we
  here define a high-level action data type. When targeting OpenFlow 1.0,
  action translates to 1.0 action sequences and controller round-trips
  if needed. When targeting OpenFlow 1.3, action also builds group
    tables to realize actions efficiently. This requires a global analysis
    of all the actions in a flow table. Therefore, Frenetic needs to
    supply the entire flow table at once and cannot add and remove flow table
  entries individually. *)
type action =
  | OutputAllPorts
  | OutputPort of portId
  | SetField of field * fieldVal
  | Seq of action * action (** directly corresponds to an _action sequence_ *)
  | Par of action * action 
  | Failover of portId * action * action

type timeout =
  | Permanent (** No timeout. *)
  | ExpiresAfter of int16 (** Time out after [n] seconds. *)

type flow = {
  pattern: pattern;
  action: action;
  cookie: int64;
  idle_timeout: timeout;
  hard_timeout: timeout
}

(** Priorities are implicit *)
type flowTable = flow list 

(** {1 Controller Packet Processing} *)

(** The payload for [packetIn] and [packetOut] messages. *)
type payload =
  | Buffered of bufferId * bytes 
    (** [Buffered (id, buf)] is a packet buffered on a switch. *)
  | NotBuffered of bytes

type packetInReason =
  | NoMatch
  | ExplicitSend

(** [(payload, total_length, in_port, reason)] *)
type pktIn = payload * int * portId * packetInReason

(* {1 Switch Configuration} *)

(** A simplification of the _switch features_ message from OpenFlow *)
type switchFeatures = {
  switch_id : switchId;
  switch_ports : portId list
}

(* {1 Statistics} *)

(** The body of a reply to an individual flow statistics request. *)
type flowStats = {
  flow_table_id : int8; (** ID of table flow came from. *)
  flow_pattern : pattern;
  flow_duration_sec: int32;
  flow_duration_nsec: int32;
  flow_priority: int16;
  flow_idle_timeout: int16;
  flow_hard_timeout: int16;
  flow_action: action;
  flow_packet_count: int64;
  flow_byte_count: int64
}

(* {1 Errors} *)

(* TODO: FILL *)

(* {1 Pretty-printing } *)

val format_portId : Format.formatter -> portId -> unit
val format_switchId : Format.formatter -> switchId -> unit

module type SWITCH = sig

  type t
  (** [setup_flow_table sw tbl] returns after [sw] is configured to implement 
      [tbl]. [setup_flow_table] fails if [sw] runs a version of OpenFlow that
      does not support the features that [tbl] requires. *)
  val setup_flow_table : t -> flowTable -> unit Lwt.t
  val flow_stats_request : t -> pattern -> flowStats list Lwt.t
  val packet_in : t -> pktIn Lwt_stream.t
  val packet_out : t -> payload -> action -> unit Lwt.t
  val disconnect : t -> unit Lwt.t
  val features : t -> switchFeatures
end