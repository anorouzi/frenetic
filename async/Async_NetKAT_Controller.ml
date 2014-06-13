open Core.Std
open Async.Std

module Net = Async_NetKAT.Net

module Controller = Async_OpenFlow.OpenFlow0x01.Controller
module Stage = Async_OpenFlow.Stage
module SDN = SDN_Types

type switchId = SDN_Types.switchId

module SwitchMap = Map.Make(Int64)
module XidMap = Map.Make(Int32)

module Log = Async_OpenFlow.Log

let max_pending_connections = 64

let _ = Log.set_level `Info

let _ = Log.set_output
          [Log.make_filtered_output
             [("openflow", "socket");
              ("openflow", "platform");
              ("openflow", "serialization");
              ("openflow", "controller");
              ("openflow", "openflow0x01");
              ("netkat", "topology.switch");
              ("netkat", "topology.host");
              ("netkat", "learning")]]

let tags = [("openflow", "controller")]

exception Assertion_failed of string

type t = {
  ctl : Controller.t;
  txn : Txn.t;
  nib : Net.Topology.t ref;
  app : Async_NetKAT.app;
  mutable edge : (SDN_Types.flow*int) list SwitchMap.t;
}

let bytes_to_headers
  (port_id : SDN_Types.portId)
  (bytes : Cstruct.t)
  : NetKAT_Types.HeadersValues.t =
  let open NetKAT_Types.HeadersValues in
  let open Packet in
  let pkt = Packet.parse bytes in
  { location = NetKAT_Types.Physical port_id
  ; ethSrc = pkt.dlSrc
  ; ethDst = pkt.dlDst
  ; vlan = (match pkt.dlVlan with Some (v) -> v | None -> 0)
  ; vlanPcp = pkt.dlVlanPcp
  ; ethType = dlTyp pkt
  ; ipProto = (try nwProto pkt with Invalid_argument(_) -> 0)
  ; ipSrc = (try nwSrc pkt with Invalid_argument(_) -> 0l)
  ; ipDst = (try nwDst pkt with Invalid_argument(_) -> 0l)
  ; tcpSrcPort = (try tpSrc pkt with Invalid_argument(_) -> 0)
  ; tcpDstPort = (try tpDst pkt with Invalid_argument(_) -> 0)
  }


let headers_to_actions
  (h_new:NetKAT_Types.HeadersValues.t)
  (h_old:NetKAT_Types.HeadersValues.t)
  : SDN_Types.action list =
  let open SDN_Types in
  let g p acc f =
    if (Field.get f h_new) = (Field.get f h_old)
      then acc
      else (p (Field.get f h_new))::acc in
  let init = match h_new.NetKAT_Types.HeadersValues.location with
     | NetKAT_Types.Pipe p ->
       raise (Assertion_failed (Printf.sprintf
         "Controller.headers_to_action: impossible pipe location \"%s\"" p))
     | NetKAT_Types.Physical p -> [Output(Physical(p))] in
  NetKAT_Types.HeadersValues.Fields.fold
    ~init
    ~location:(fun acc f -> acc)
    ~ethSrc:(g (fun v -> Modify(SetEthSrc v)))
    ~ethDst:(g (fun v -> Modify(SetEthDst v)))
    ~vlan:(g (fun v -> Modify(SetVlan (Some(v)))))
    ~vlanPcp:(g (fun v -> Modify(SetVlanPcp v)))
    ~ethType:(g (fun v -> Modify(SetEthTyp v)))
    ~ipProto:(g (fun v -> Modify(SetIPProto v)))
    ~ipSrc:(g (fun v -> Modify(SetIP4Src v)))
    ~ipDst:(g (fun v -> Modify(SetIP4Dst v)))
    ~tcpSrcPort:(g (fun v -> Modify(SetTCPSrcPort v)))
    ~tcpDstPort:(g (fun v -> Modify(SetTCPDstPort v)))

exception Unsupported_mod of string

let packet_sync_headers (pkt:NetKAT_Types.packet) : NetKAT_Types.packet * bool =
  let open NetKAT_Types in
  let change = ref false in
  let g p q acc f =
    let v = Field.get f pkt.headers in
    if p v acc then
      acc
    else begin
      change := true;
      q acc v
    end in
  let fail field = (fun _ -> raise (Unsupported_mod field)) in
  let packet = Packet.parse (SDN_Types.payload_bytes pkt.payload) in
  let packet' = HeadersValues.Fields.fold
    ~init:packet
    ~location:(fun acc _ -> acc)
    ~ethSrc:(g (fun v p -> v = p.Packet.dlSrc) Packet.setDlSrc)
    ~ethDst:(g (fun v p -> v = p.Packet.dlDst) Packet.setDlDst)
    (* XXX(seliopou): Fix impls of: vlan, vlanPcp *)
    ~vlan:(g (fun _ _ -> true) (fail "vlan"))
    ~vlanPcp:(g (fun _ _ -> true) (fail "vlanPcp"))
    ~ipSrc:(g
      (fun v p -> try v = Packet.nwSrc p with Invalid_argument(_) -> true)
      (fun acc nw -> Packet.setNwSrc acc nw))
    ~ipDst:(g
      (fun v p -> try v = Packet.nwDst p with Invalid_argument(_) -> true)
      (fun acc nw -> Packet.setNwDst acc nw))
    ~tcpSrcPort:(g
      (fun v p -> try v= Packet.tpSrc p with Invalid_argument(_) -> true)
      Packet.setTpSrc)
    ~tcpDstPort:(g
      (fun v p -> try v = Packet.tpDst p with Invalid_argument(_) -> true)
      Packet.setTpDst)
    (* XXX(seliopou): currently does not support: *)
    ~ethType:(g (fun _ _ -> true) (fail "ethType"))
    ~ipProto:(g (fun _ _ -> true) (fail "ipProto")) in
  ({ pkt with payload = match pkt.payload with
    | SDN_Types.NotBuffered(_) -> SDN_Types.NotBuffered(Packet.marshal packet')
    | SDN_Types.Buffered(n, _) -> SDN_Types.Buffered(n, Packet.marshal packet')
  }, !change)

let send t c_id msg =
  Controller.send t c_id msg
  >>| function
    | `Sent _ -> ()
    | `Drop exn -> raise exn

let send_barrier_to_sw (t : t) (sw_id : switchId)
  : [`Disconnect of Sexp.t | `Complete ] Deferred.t =
  let c_id = Controller.client_id_of_switch t.ctl sw_id in
  Txn.send t.txn c_id OpenFlow0x01.Message.BarrierRequest
  >>= function
    | `Sent ivar ->
      begin Ivar.read ivar
      >>| function
        | `Result OpenFlow0x01.Message.BarrierReply -> `Complete
        | `Result _ -> assert false
        | `Disconnect exn_ -> `Disconnect exn_
      end
    | `Drop exn -> raise exn

let port_desc_useable (pd : OpenFlow0x01.PortDescription.t) : bool =
  let open OpenFlow0x01.PortDescription in
  if pd.config.PortConfig.down
    then false
    else not (pd.state.PortState.down)

let to_event (w_out : (switchId * SDN_Types.pktOut) Pipe.Writer.t)
  : (t, Controller.f, NetKAT_Types.event) Stage.t =
  let open NetKAT_Types in
  fun t evt -> match evt with
    | `Connect (c_id, feats) ->
      let ports = feats.OpenFlow0x01.SwitchFeatures.ports in
      let sw_id = feats.OpenFlow0x01.SwitchFeatures.switch_id in
      (* Generate a SwitchUp event, and PortUp event for ever port that is
       * useable. *)
      return ((SwitchUp sw_id) :: (List.fold ports ~init:[] ~f:(fun acc pd ->
        let open OpenFlow0x01.PortDescription in
        if port_desc_useable pd && pd.port_no < 0xff00 then
          let pt_id = Int32.of_int_exn pd.port_no in
          PortUp(sw_id, pt_id)::acc
        else
          acc)))
    | `Disconnect (c_id, switch_id, exn) ->
      Log.debug ~tags "switch %Ld disconnected" switch_id;
      let open Net.Topology in
      let v  = vertex_of_label !(t.nib) (Async_NetKAT.Switch switch_id) in
      let ps = vertex_to_ports !(t.nib) v in
      return (PortSet.fold (fun p acc -> (PortDown(switch_id, p))::acc)
        ps [SwitchDown switch_id])
    | `Message (c_id, (xid, msg)) ->
      let open OpenFlow0x01.Message in
      let switch_id = Controller.switch_id_of_client t.ctl c_id in
      begin match msg with
        | PacketInMsg pi ->
          let open OpenFlow0x01_Core in
          let port_id = Int32.of_int_exn pi.port in
          let payload = SDN_OpenFlow0x01.to_payload pi.input_payload in
          let local =
            Optimize.specialize_policy switch_id (Async_NetKAT.default t.app) in
          (* Eval the packet to get the list of packets that should go to
           * pipes, and the list of packets that can be forwarded to physical
           * locations.
           * *)
          let pkt0 = {
            switch = switch_id;
            headers = bytes_to_headers port_id (SDN_Types.payload_bytes payload);
            payload = payload;
          } in
          begin
            (* XXX(seliopou): What if the packet's modified? Should buf_id be
             * exposed to the application?
             * *)
            let pis, phys = NetKAT_Semantics.eval_pipes pkt0 local in
            let outs = Deferred.List.iter phys ~f:(fun pkt1 ->
              let acts = headers_to_actions pkt1.headers pkt0.headers in
              let out  = (switch_id, (payload, Some(port_id), acts)) in
              Pipe.write w_out out) in
            outs >>= fun _ ->
            return (List.map pis ~f:(fun (pipe, pkt2) ->
              let pkt3, changed = packet_sync_headers pkt2 in
              let payload = match payload, changed with
                  | SDN_Types.NotBuffered(_), _
                  | _                       , true ->
                    SDN_Types.NotBuffered(SDN_Types.payload_bytes pkt3.payload)
                  | SDN_Types.Buffered(buf_id, bytes), false ->
                    SDN_Types.Buffered(buf_id, bytes)
              in
              PacketIn(pipe, switch_id, port_id, payload, pi.total_len)))
          end
        | PortStatusMsg ps ->
          let open OpenFlow0x01.PortStatus in
          let open OpenFlow0x01.PortDescription in
          begin match ps.reason, port_desc_useable ps.desc with
            | ChangeReason.Add, true
            | ChangeReason.Modify, true ->
              let pt_id = Int32.of_int_exn (ps.desc.port_no) in
              return [PortUp(switch_id, pt_id)]
            | ChangeReason.Delete, _
            | ChangeReason.Modify, false ->
              let pt_id = Int32.of_int_exn (ps.desc.port_no) in
              return [PortDown(switch_id, pt_id)]
            | _ ->
              return []
          end
        | _ ->
          Log.debug ~tags "Dropped message from %Lu: %s" switch_id (to_string msg);
          return []
      end

let compute_internal_table ver internal_ports table =
  let open SDN_Types in
  let open Async_NetKAT.Net.Topology in
  let rec fix_actions = function
    | Output (Physical pt) :: acts ->
      if not (PortSet.mem pt internal_ports)
      then
        (Modify (SetVlan None)) :: (Output (Physical pt)) :: (fix_actions acts)
      else
        (Modify (SetVlan (Some ver))) :: (Output (Physical pt)) :: (fix_actions acts)
    | Output (Controller n) :: acts ->
      (Modify (SetVlan None)) :: (Output (Controller n)) :: (fix_actions acts)
    | Output _ :: acts ->
      raise (Assertion_failed "Controller.compute_internal_table: Port not supported by consistent updates")
    | act :: acts ->
      act :: (fix_actions acts)
    | [] -> [] in
  let open Pattern in
  let match_table = List.fold table ~init:[] ~f:(fun acc r ->
      {r with pattern = {r.pattern with dlVlan = Some ver}} :: acc) in
  List.fold match_table ~init:[] ~f:(fun acc r ->
      {r with action = List.map r.action ~f:(fun x -> List.map x ~f:(fix_actions))} :: acc)
    
let internal_update_table_for (t : t) ver pol (sw_id : switchId) : unit Deferred.t =
  let to_flow_mod prio flow =
    OpenFlow0x01.Message.FlowModMsg (SDN_OpenFlow0x01.from_flow prio flow) in
  let c_id = Controller.client_id_of_switch t.ctl sw_id in
  let table = NetKAT_LocalCompiler.(to_table (compile sw_id pol)) in
  Monitor.try_with ~name:"internal_update_table_for" (fun _ ->
    let priority = ref 65536 in
    (* Add match on ver *)    
    let table = compute_internal_table ver (TUtil.internal_ports !(t.nib) sw_id) table in
    (* Log.debug ~tags
      "switch %Lu: Installing internal table %s" sw_id (SDN_Types.string_of_flowTable table);
    *)
    Log.debug ~tags
      "switch %Lu: Installing internal table for ver %d" sw_id ver;
    let open SDN_Types in
    if List.length table <= 0
    then raise (Assertion_failed (Printf.sprintf
                                    "Controller.internal_update_table_for: empty table for switch %Lu" sw_id));
    Deferred.List.iter table ~f:(fun flow ->
        decr priority;
        send t.ctl c_id (0l, to_flow_mod !priority flow))
    >>= fun () -> (send_barrier_to_sw t sw_id))
  >>= function
  | Ok `Complete ->
    Log.debug ~tags
      "switch %Lu: installed internal table for ver %d" sw_id ver;
    Log.flushed ()
  | Ok (`Disconnect exn_) ->
    Log.debug ~tags
      "switch %Lu: disconnected while installing internal table for ver %d... skipping" sw_id ver;
    Log.flushed ()
  | Error exn -> raise exn

let compute_edge_table ver internal_ports table =
  let vlan_none = 65535 in
  (* Fold twice: once to fix match, second to fix fwd *)
  let open SDN_Types in
  let open Async_NetKAT.Net.Topology in
  let rec fix_actions = function
    | Output (Physical pt) :: acts ->
      if not (PortSet.mem pt internal_ports)
      then
        (Modify (SetVlan None)) :: (Output (Physical pt)) :: (fix_actions acts)
      else
        (Modify (SetVlan (Some ver))) :: (Output (Physical pt)) :: (fix_actions acts)
    | Output (Controller n) :: acts ->
      (Modify (SetVlan None)) :: (Output (Controller n)) :: (fix_actions acts)
    | Output _ :: acts ->
      raise (Assertion_failed "Controller.compute_edge_table: Port not supported by consistent updates")
    | act :: acts ->
      act :: (fix_actions acts)
    | [] -> []
  in
  let open Pattern in
  let match_table = List.fold table ~init:[] ~f:(fun acc r ->
      begin
        match r.pattern.inPort with
        | Some pt ->
          if PortSet.mem pt internal_ports
          then acc
          else {r with pattern = {r.pattern with dlVlan = Some vlan_none}} :: acc
        | None ->
          {r with pattern = {r.pattern with dlVlan = Some vlan_none}} :: acc
      end)
  in
  List.fold match_table ~init:[] ~f:(fun acc r ->
      {r with action = List.map r.action ~f:(fun x -> List.map x ~f:(fix_actions))} :: acc)

(* Comparison should be made based on patterns only, not actions *)
(* Assumes both FT are sorted in descending order by priority *)
let rec flowtable_diff (ft1 : (SDN_Types.flow*int) list) (ft2 : (SDN_Types.flow*int) list) =
  let open SDN_Types in
  match ft1,ft2 with
  | (flow1,pri1)::ft1, (flow2,pri2)::ft2 ->
    if pri1 > pri2
    then (flow1, pri1) :: flowtable_diff ft1 ((flow2,pri2)::ft2)
    else if pri1 = pri2 && flow1.pattern = flow2.pattern
    then flowtable_diff ft1 ((flow2,pri2)::ft2)
    else
      flowtable_diff ((flow1,pri1) :: ft1) ft2
  | _, [] -> ft1
  | [], _ -> []

(* Assumptions:
   - switch respects priorities when deleting flows
*)
let swap_update_for (t : t) sw_id new_table : unit Deferred.t =
  let open OpenFlow0x01_Core in
  let max_priority = 65535 in
  let old_table = match SwitchMap.find t.edge sw_id with
    | Some ft -> ft
    | None -> [] in
  let (new_table, _) = List.fold new_table ~init:([], max_priority)
      ~f:(fun (acc,pri) x -> ((x,pri) :: acc, pri - 1)) in
  let new_table = List.rev new_table in
  let del_table = List.rev (flowtable_diff old_table new_table) in
  let c_id = Controller.client_id_of_switch t.ctl sw_id in
  let to_flow_mod prio flow =
    OpenFlow0x01.Message.FlowModMsg (SDN_OpenFlow0x01.from_flow prio flow) in
  let to_flow_del prio flow =
    OpenFlow0x01.Message.FlowModMsg ({SDN_OpenFlow0x01.from_flow prio flow with command = DeleteStrictFlow}) in
  (* Install the new table *)
  Deferred.List.iter new_table ~f:(fun (flow, prio) ->
      send t.ctl c_id (0l, to_flow_mod prio flow))
  (* Delete the old table from the bottom up *)
  >>= fun () -> Deferred.List.iter del_table ~f:(fun (flow, prio) ->
      send t.ctl c_id (0l, to_flow_del prio flow))
  >>= fun () -> (t.edge <- SwitchMap.add t.edge sw_id new_table;
       return ())


let edge_update_table_for (t : t) ver pol (sw_id : switchId) : unit Deferred.t =
  let table = NetKAT_LocalCompiler.(to_table (compile sw_id pol)) in
  Monitor.try_with ~name:"edge_update_table_for" (fun _ ->
      let edge_table = compute_edge_table ver (TUtil.internal_ports !(t.nib) sw_id) table in
      (*
      Log.debug ~tags
        "switch %Lu: Installing edge table %s" sw_id (SDN_Types.string_of_flowTable edge_table);
      *)
      Log.debug ~tags
        "switch %Lu: Installing edge table for ver %d" sw_id ver;
      swap_update_for t sw_id edge_table
      >>= fun () -> (send_barrier_to_sw t sw_id))
  >>= function
  | Ok `Complete ->
    Log.debug ~tags
      "switch %Lu: installed edge table for ver %d" sw_id ver;
    Log.flushed ()
  | Ok (`Disconnect exn_) ->
    Log.debug ~tags
      "switch %Lu: disconnected while installing edge table for ver %d... skipping" sw_id ver;
    Log.flushed ()
  | Error exn -> raise exn

let clear_old_table_for (t : t) ver sw_id : unit Deferred.t =
  let open SDN_Types in
  let open OpenFlow0x01_Core in  
  let delete_flows =
    OpenFlow0x01.Message.FlowModMsg {
      (SDN_OpenFlow0x01.from_flow 0
         {pattern = { Pattern.match_all with Pattern.dlVlan = Some ver};
          action = [];
          cookie = 0L;
          idle_timeout = Permanent;
          hard_timeout = Permanent})
      with command = DeleteFlow} in
  let c_id = Controller.client_id_of_switch t.ctl sw_id in
  Monitor.try_with ~name:"clear_old_table_for" (fun () ->
      send t.ctl c_id (5l, delete_flows))
  >>= function
  | Ok () -> return ()
  | Error exn_ ->
    Log.error ~tags
      "switch %Lu: Failed to update table in delete_flows" sw_id;
    Log.flushed ()

let ver = ref 1 
  
let consistently_update_table (t : t) pol : unit Deferred.t =
  let switches = TUtil.switch_ids !(t.nib) in
  let ver_num = !ver + 1 in
  (* Install internal update *)
  Log.debug ~tags "Installing internal tables for ver %d" ver_num;
  Log.flushed ()
  >>= fun () ->
  Deferred.List.iter switches (internal_update_table_for t ver_num pol)
  >>= fun () ->
  (Log.debug ~tags "Installing edge tables for ver %d" ver_num;
   Log.flushed ())
  >>= fun () ->
  (* Install edge update *)
  Deferred.List.iter switches (edge_update_table_for t ver_num pol)
  >>= fun () ->
  (* Delete old rules *)
  Deferred.List.iter switches (clear_old_table_for t (ver_num - 1))
  >>= fun () ->
  return (incr ver)

let handler
  ?(update=`BestEffort)
  (t : t)
  (w : (switchId * SDN_Types.pktOut) Pipe.Writer.t)
  (app : Async_NetKAT.app)
  : (NetKAT_Types.event -> unit Deferred.t) =
  let app' = Async_NetKAT.run app t.nib w () in
  let updater = match update with
    | `BestEffort ->
      fun t -> Update.BestEffort.implement_policy t.ctl !(t.nib)
    | `PerPacketConsistent -> consistently_update_table in
  fun e ->
    app' e >>= fun m_pol ->
    match m_pol with
    | Some (pol) ->
      updater t pol
    | None ->
      begin match e with
        | NetKAT_Types.SwitchUp sw_id ->
          (* BUG: Switches coming up that don't trigger a policy update will not
           * get a versioned polocy when consistent updates are turned on. *)
          Update.BestEffort.bring_up_switch t.ctl sw_id (Async_NetKAT.default app)
        | _ -> return ()
      end

let start app ?(port=6633) ?(update=`BestEffort) () =
  let open Async_OpenFlow.Stage in
  Controller.create ~log_disconnects:true ~max_pending_connections ~port ()
  >>> fun ctl ->
  let t = {
    ctl = ctl;
    txn = Txn.create ctl;
    nib = ref (Net.Topology.empty ());
    app = app;
    edge = SwitchMap.empty;
  } in

  (* The pipe for packet_outs. The Pipe.iter below will run in its own logical
   * thread, sending packet outs to the switch whenever it's scheduled.
   *)
  let r_out, w_out = Pipe.create () in
  Deferred.don't_wait_for (Pipe.iter r_out ~f:(fun out ->
      let (sw_id, pkt_out) = out in
      Monitor.try_with ~name:"packet_out" (fun () ->
          let c_id = Controller.client_id_of_switch ctl sw_id in
          send ctl c_id (0l, OpenFlow0x01.Message.PacketOutMsg
                           (SDN_OpenFlow0x01.from_packetOut pkt_out)))
      >>= function
      | Ok () -> return ()
      | Error exn_ ->
        Log.error ~tags "switch %Lu: Failed to send packet_out" sw_id;
        Log.flushed ()));
  let stages = let open Controller in
    (local (fun t -> t.ctl) features)
    >=> (local (fun t -> t.txn) Txn.stage)
    >=> (to_event w_out) in
  
  (* Build up the application by adding topology discovery into the mix. *)
  let d_ctl, topo = Discovery.create () in
  let app = Async_NetKAT.union ~how:`Sequential topo (Discovery.guard app) in
  let sdn_events = run stages t (Controller.listen ctl) in
  (* The discovery application itself will generate events, so the actual
   * event stream must be a combination of switch events and synthetic
   * topology discovery events. Pipe.interleave will wait until one of the
   * pipes is readable, take a batch, and send it along.
   *
   * Whatever happens, happens. Can't stop won't stop.
   * *)
  let events = Pipe.interleave [Discovery.events d_ctl; sdn_events] in
  begin match update with
  | `PerPacketConsistent ->
    (* XXX(seliopou): budget has to be big, otherwise consistent updates will
     * lead to deadlocks where event processing is blocked on a table update,
     * but the table update can't complete until an event, specifically a
     * barrier reply, is processed.
     *
     * This and other parameters need to be tweaked. This'll happen in the app
     * branch. For now, the parameter is set so that the controller can manage a
     * topo,2,3 and achieve connectivity with --learn enabled.
     *)
    Pipe.set_size_budget events 50
  | `BestEffort -> ()
  end;

  Deferred.don't_wait_for (
    Monitor.try_with ~name:"start" (fun () ->
        (Pipe.iter events ~f:(handler ~update t w_out app)))
    >>= function
    | Ok a -> return a
    | Error exn_ ->
      Log.error ~tags "start: Exception occured %s" (Exn.to_string exn_);
      Log.flushed ())
