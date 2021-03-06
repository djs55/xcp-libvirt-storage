(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Xcp_service

let driver = "libvirt"
let name = "sm-libvirt"
let description = "XCP -> libvirt storage connector"
let vendor = "Citrix"
let copyright = "Citrix Inc"
let minor_version = 1
let major_version = 0
let version = Printf.sprintf "%d.%d" major_version minor_version
let required_api_version = "2.0"
let features = [
  "VDI_CREATE";
  "VDI_DELETE";
  "VDI_ATTACH";
  "VDI_DETACH";
  "VDI_ACTIVATE";
  "VDI_DEACTIVATE";
]
let _xml  = "xml"
let _name = "name"
let _uri  = "uri"
let configuration = [
   _xml, "XML fragment describing the storage pool configuration";
   _name, "name of the libvirt storage pool";
   _uri, "URI of the hypervisor to use";
]

let json_suffix = ".json"
let state_path = Printf.sprintf "/var/run/nonpersistent/%s%s" name json_suffix

module D = Debug.Make(struct let name = "ffs" end)
open D

module C = Libvirt.Connect
module P = Libvirt.Pool
module V = Libvirt.Volume

let conn = ref None

let get_connection ?name () = match !conn with
  | None ->
    let c = C.connect ?name () in
    conn := Some c;
    c
  | Some c -> c

type sr = {
  pool: Libvirt.rw P.t;
}

let finally f g =
  try
    let result = f () in
    g ();
    result
  with e ->
    g ();
    raise e

let string_of_file filename =
  let ic = open_in filename in
  let output = Buffer.create 1024 in
  try
    while true do
      let block = String.make 4096 '\000' in
      let n = input ic block 0 (String.length block) in
      if n = 0 then raise End_of_file;
      Buffer.add_substring output block 0 n
    done;
    "" (* never happens *)
  with End_of_file ->
    close_in ic;
    Buffer.contents output

let file_of_string filename string =
  let oc = open_out filename in
  finally
    (fun () ->
      debug "write >%s %s" filename string;
      output oc string 0 (String.length string)
    ) (fun () -> close_out oc)

let run cmd =
  info "shell %s" cmd;
  let f = Filename.temp_file name name in
  let cmdline = Printf.sprintf "%s > %s 2>&1" cmd f in
  let code = Sys.command cmdline in
  let output = string_of_file f in
  let _ = Sys.command (Printf.sprintf "rm %s" f) in
  if code = 0
  then output
  else failwith (Printf.sprintf "%s: %d: %s" cmdline code output)

let startswith prefix x =
  let prefix' = String.length prefix in
  let x' = String.length x in
  x' >= prefix' && (String.sub x 0 prefix' = prefix)

let remove_prefix prefix x =
  let prefix' = String.length prefix in
  let x' = String.length x in
  String.sub x prefix' (x' - prefix')

let endswith suffix x =
  let suffix' = String.length suffix in
  let x' = String.length x in
  x' >= suffix' && (String.sub x (x' - suffix') suffix' = suffix)

let iso8601_of_float x = 
  let time = Unix.gmtime x in
  Printf.sprintf "%04d%02d%02dT%02d:%02d:%02dZ"
    (time.Unix.tm_year+1900)
    (time.Unix.tm_mon+1)
    time.Unix.tm_mday
    time.Unix.tm_hour
    time.Unix.tm_min
    time.Unix.tm_sec

let ( |> ) a b = b a

open Storage_interface

module Attached_srs = struct
  let table = Hashtbl.create 16
  let get id =
    if not(Hashtbl.mem table id)
    then raise (Sr_not_attached id)
    else Hashtbl.find table id
  let put id sr =
    if Hashtbl.mem table id
    then raise (Sr_attached id)
    else Hashtbl.replace table id sr
  let remove id =
    if not(Hashtbl.mem table id)
    then raise (Sr_not_attached id)
    else Hashtbl.remove table id
  let num_attached () = Hashtbl.fold (fun _ _ acc -> acc + 1) table 0
end

let report_libvirt_error f x =
  try
    f x
  with Libvirt.Virterror t ->
    error "from libvirt: %s" (Libvirt.Virterror.to_string t);
    raise (Backend_error ("libvirt", [Libvirt.Virterror.to_string t]))


module Implementation = struct
  type context = unit

  module Query = struct
    let query ctx ~dbg = {
        driver;
        name;
        description;
        vendor;
        copyright;
        version;
        required_api_version;
        features;
        configuration;
    }

    let diagnostics ctx ~dbg = "Not available"
  end
  module DP = struct include Storage_skeleton.DP end
  module VDI = struct
    (* The following are all not implemented: *)
    open Storage_skeleton.VDI
    let clone = clone
    let snapshot = snapshot
    let epoch_begin = epoch_begin
    let epoch_end = epoch_end
    let get_url = get_url
    let set_persistent = set_persistent
    let compose = compose
    let similar_content = similar_content
    let add_to_sm_config = add_to_sm_config
    let remove_from_sm_config = remove_from_sm_config
    let set_content_id = set_content_id
    let get_by_name = get_by_name
    let resize = resize

    let example_volume_xml = "
       <volume>
         <name>myvol</name>
         <key>rbd/myvol</key>
         <source>
         </source>
         <capacity unit='bytes'>53687091200</capacity>
         <allocation unit='bytes'>53687091200</allocation>
         <target>
           <path>rbd:rbd/myvol</path>
           <format type='unknown'/>
           <permissions>
             <mode>00</mode>
             <owner>0</owner>
             <group>0</group>
           </permissions>
         </target>
       </volume>
    "
    
    let read_xml_path path' xml =
      let input = Xmlm.make_input (`String (0, xml)) in
      let rec search path = match Xmlm.input input with
      | `Dtd _ -> search path
      | `El_start ((_, x), _) -> search (x :: path)
      | `El_end -> search (List.tl path)
      | `Data x when path = path' -> x
      | `Data _ -> search path in
      search []

    let volume_target_path = [ "path"; "target"; "volume" ]

    let vdi_path_of key =
      let c = get_connection () in
      let v = V.lookup_by_key c key in
      let xml = V.get_xml_desc (V.const v) in
      read_xml_path volume_target_path xml 

    let vdi_vol_of key =
      let c = get_connection () in
      let v = V.lookup_by_key c key in
      V.get_name (V.const v)

    let vdi_info_of_name pool name =
        try
          let v = V.lookup_by_name pool name in
          let info = V.get_info v in
          let key = V.get_key v in
          Some {
              vdi = key;
              content_id = "";
              name_label = name;
              name_description = "";
              ty = "user";
              metadata_of_pool = "";
              is_a_snapshot = false;
              snapshot_time = iso8601_of_float 0.;
              snapshot_of = "";
              read_only = false;
              virtual_size = info.V.capacity;
              physical_utilisation = info.V.allocation;
              sm_config = [];
              persistent = true;
          }
        with Libvirt.Virterror t ->
          error "Error while looking up volume: %s: %s" name (Libvirt.Virterror.to_string t);
          None
        | e ->
          error "Error while looking up volume: %s: %s" name (Printexc.to_string e);
          None

    let choose_filename sr name_label =
      let pool = Libvirt.Pool.const sr.pool in
      let count = Libvirt.Pool.num_of_volumes pool in
      let existing = Array.to_list (Libvirt.Pool.list_volumes pool count) in

      if not(List.mem name_label existing)
      then name_label
      else
        let stem = name_label ^ "." in
        let with_common_prefix = List.filter (startswith stem) existing in
        let suffixes = List.map (remove_prefix stem) with_common_prefix in
        let highest_number = List.fold_left (fun acc suffix ->
          let this = try int_of_string suffix with _ -> 0 in
          max acc this) 0 suffixes in
        stem ^ (string_of_int (highest_number + 1))


    let create ctx ~dbg ~sr ~vdi_info =
      let sr = Attached_srs.get sr in
      let name = vdi_info.name_label ^ ".img" in
      (* If this volume already exists, make a different name which is
         unique. NB this is not concurrency-safe *)
      let name =
        if vdi_info_of_name (P.const sr.pool) name = None
        then name
        else
          let name' = choose_filename sr name in
          info "Rewriting name from %s to %s to guarantee uniqueness" name name';
          name' in 

      let xml = Printf.sprintf "
        <volume>
          <name>%s</name>
          <capacity unit=\"B\">%Ld</capacity>
        </volume>
      " name vdi_info.virtual_size in
      report_libvirt_error (Libvirt.Volume.create_xml sr.pool) xml;
      match vdi_info_of_name (P.const sr.pool) name with
      | Some x -> x
      | None ->
        failwith "Failed to find volume in storage pool: create silently failed?"

    let destroy ctx ~dbg ~sr ~vdi =
      let c = get_connection () in
      let v = V.lookup_by_path c vdi in
      report_libvirt_error (V.delete v) V.Normal

    let stat ctx ~dbg ~sr ~vdi = assert false
    let attach ctx ~dbg ~dp ~sr ~vdi ~read_write =
      let path = vdi_path_of vdi in
      {
        params = path;
        xenstore_data = [
          "type", "rbd";
          "name", "rbd:" ^ vdi; (* XXX some versions of qemu require this hack *)
        ]
      }
    let detach ctx ~dbg ~dp ~sr ~vdi =
      let _ = vdi_path_of vdi in
      ()
    let activate ctx ~dbg ~dp ~sr ~vdi = ()
    let deactivate ctx ~dbg ~dp ~sr ~vdi = ()
  end
  module SR = struct
    open Storage_skeleton.SR
    let list = list
    let update_snapshot_info_src = update_snapshot_info_src
    let update_snapshot_info_dest = update_snapshot_info_dest
    let stat = stat
    let scan ctx ~dbg ~sr =
       let sr = Attached_srs.get sr in
       let pool = Libvirt.Pool.const sr.pool in
       let count = Libvirt.Pool.num_of_volumes pool in
       report_libvirt_error (Libvirt.Pool.list_volumes pool) count
       |> Array.to_list
       |> List.map (VDI.vdi_info_of_name pool)
       |> List.fold_left (fun acc x -> match x with
             | None -> acc
             | Some x -> x :: acc) []

    let destroy = destroy
    let reset = reset
    let detach ctx ~dbg ~sr =
       Attached_srs.remove sr;
       if Attached_srs.num_attached () = 0
       then match !conn with
       | Some c ->
            C.close c;
            conn := None
       | None -> ()

    let optional device_config key =
      if List.mem_assoc key device_config
      then Some (List.assoc key device_config)
      else None
    let require device_config key =
      if not(List.mem_assoc key device_config) then begin
        error "Required device_config:%s not present" key;
        raise (Missing_configuration_parameter key)
      end else List.assoc key device_config


    let attach ctx ~dbg ~sr ~device_config =
       let name = require device_config _name in
       let uri = optional device_config _uri in
       let c = get_connection ?name:uri () in
       let pool = P.lookup_by_name c name in
       Attached_srs.put sr { pool }

    let create ctx ~dbg ~sr ~device_config ~physical_size =
       let name = require device_config _name in
       let uri = optional device_config _uri in
       let xml = require device_config _xml in
       let xml = Printf.sprintf "
         <pool type=\"dir\">
           <name>%s</name>
           %s
         </pool>
       " name xml in
       let c = get_connection ?name:uri () in
       let _ = report_libvirt_error (Libvirt.Pool.create_xml c) xml in
       ()
  end
  module UPDATES = struct include Storage_skeleton.UPDATES end
  module TASK = struct include Storage_skeleton.TASK end
  module Policy = struct include Storage_skeleton.Policy end
  module DATA = struct include Storage_skeleton.DATA end
  let get_by_name = Storage_skeleton.get_by_name
end

module Server = Storage_interface.Server(Implementation)

