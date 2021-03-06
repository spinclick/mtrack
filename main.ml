open Lwt.Infix ;;
open Extensions ;;

module Db = Database ;;
module Yj = Yojson.Safe ;;

type gps_update_data =
  { lat : float;
    lon : float; } ;;

type ap_update_data = 
  { ssid : string ;
    bssid : string ; } ;;

type update_data = 
    GPS of gps_update_data 
  | APS of ap_update_data list ;;

type query_special = All ;;
type query = 
    Users of string list
  | Location of string
  | Special of query_special ;;

type api_update = 
  { id : string ;
    data : update_data } ;;

type api_query = 
  { id: string;
    t : query }

type api_create =
  { user : string } ;;

type api = Update of Yj.json | Query of Yj.json | Create of Yj.json ;;
type create_response = CreateID of string | CreateError of string ;;
type create_status = ValidCreate of api_create | InvalidCreate of string ;;
type query_status = ValidQuery of api_query | InvalidQuery ;;
type username_status = ValidName | InvalidName of string ;;
exception Err of string ;;

(* Shorthands *)
let return_unit = Lwt.return_unit ;;
let return = Lwt.return ;;
let sprintf = Printf.sprintf ;;
let printfl = Lwt_io.printf ;;
let printl = Lwt_io.printl ;;
let async = Lwt.async ;;
let print_one_off msg = async (fun () -> printl msg) ;;

let string_of_aps aps =
  let string_of_ap a = sprintf "  ssid: %s, bssid: %s" a.ssid a.bssid in
  String.concat "\n" @@ 
    (List.map string_of_ap aps) ;;

let string_of_update r = 
  match r.data with
    | GPS g -> 
        sprintf "GPS Update from id='%s'\n  (%f,%f)" r.id g.lat g.lon
    | APS a ->
        sprintf "APS Update from id='%s'\n%s" r.id (string_of_aps a) ;;

let update_of_json (json : Yj.json) : api_update = 
  let to_string = Yj.Util.to_string in
  let to_float = Yj.Util.to_float in
  let gps_of_json json = 
    try { lat = to_float @@ List.assoc "lat" json ;
          lon = to_float @@ List.assoc "lon" json } 
    with Not_found -> raise @@ Err "lat/lon not found in GPS data"
  in
  let ap_of_json = function
    | `Assoc ap 
      -> (try { ssid = to_string @@ List.assoc "ssid" ap ;
                bssid = to_string @@ List.assoc "bssid" ap }
          with Not_found -> raise @@ Err  "bssid/ssid not found in AP data")
    | _ -> raise @@ Err "Expected `Assoc in ap_of_json" 
  in
  match json with
    | `Assoc [("id", `String id); data_json]
      -> (let data = 
            match data_json with
              | ("aps", `List ap_json_l) -> (APS (List.map ap_of_json ap_json_l))
              | ("gps", `Assoc json) -> (GPS (gps_of_json json))
              | _ -> raise @@ Err "Invalid data structure in update json" in
          {id = id ; data = data})
    | _ -> raise @@ Err "Invalid data structure in update json" ;;

let verify_request_length len =
  if len > Const.max_upload_len 
    then raise @@ Err "Upload length exceeds maximum"
    else len ;;

let api_of_json = function
  | `Assoc [("Update", json)] -> Update json
  | `Assoc [("Query", json)] -> Query json
  | `Assoc [("Create", json)] -> Create json
  | `Assoc [(c, _)] -> raise @@ Err (sprintf "Unknown API command '%s'" c)
  |  _ -> raise @@ Err "Invalid API format" ;;

let query_of_json = function
  | `Assoc [("id", `String id ); ("location", `String place)] -> 
      ValidQuery { id = id ; t = Location place }
  | `Assoc [("id", `String id ); ("users", `List names)] -> 
      ValidQuery { id = id ; t = Users (List.map Yj.Util.to_string names)}
  | `Assoc [("id", `String id ); ("special", `String "all")] 
     when Const.query_special_enabled -> 
      ValidQuery { id = id ; t = Special All }
  | _ -> InvalidQuery ;;

let write_update (u : api_update) = 
  let open Location in
  let time_now = Unix.time_int64 () in
  let location_name = 
    match u.data with
      | GPS g -> Location.title_of_latlon (g.lat,g.lon) Const.location_config.gpsl
      | APS a -> Location.title_of_netids 
                  (List.map (fun (a : ap_update_data) -> (a.ssid,a.bssid)) a)
                  Const.location_config.apl in
  Db.update_user u.id location_name time_now;
  return u ;;

let write_create (d : api_create) (id : string) = 
  try ignore @@ Db.create_user id d.user (Unix.time_int64 ())
  with Db.SqliteConstraint -> raise @@ Err "Contraint in create_user" ;;

let validate_username name =
  let contains_invalid_characters =
    let sane_character = function
      | 'a'..'z' | 'A'..'Z' | '0'..'9' -> true
      | _ -> false in
    List.mem false (List.map sane_character (String.explode name)) 
  in
  let name_length = (String.length name) in
  let name_too_long = name_length > Const.max_username_length in
  let name_too_short = name_length < Const.min_username_length in
  if name_too_long then
    InvalidName "Username too long"
  else if name_too_short then
    InvalidName "Username too short"
  else if contains_invalid_characters then
    InvalidName "Username contains invalid characters"
  else if (Db.user_name_exists name) then 
    InvalidName "Username already exists"
  else ValidName ;;

(* Usernames can only contain letters/numbers *)
let verify_create_data = function
  | ValidCreate d -> 
      (match (validate_username d.user) with
        | InvalidName why -> InvalidCreate why
        | ValidName -> ValidCreate d)
  | otherwise -> otherwise ;;

let response_json_of_query (dbq_l : Db.query_db_entry list) =
  let open Db in
  let json_of_query q = 
    `Assoc [("username", `String q.username);
            ("location", `String q.location);
            ("lastupdate", `Intlit (Int64.to_string q.last_update_time))]
  in
  `Assoc [("QueryResponse", (`List (List.map json_of_query dbq_l)))] ;;

let create_of_json = function
  | `Assoc [("user", `String user)] -> ValidCreate {user=user} 
  | _ -> InvalidCreate "Invalid Create request structure" ;;

let query_main io q = 
  match q.t with
    | Users users -> Db.query_by_names users
    | Location place -> Db.query_by_location place
    | Special All -> Db.query_all () ;;
  
let rec create_user_id () = 
  let buf = Bytes.create Const.id_char_length in
  let rec gen_id i = 
    let ch = char_of_int (Random.int 127) in
    match ch with
      | _ when i = (Const.id_char_length) 
          -> Bytes.to_string buf
      | 'a'..'z' | 'A'..'Z' | '0'..'9' 
          -> (Bytes.set buf i ch; gen_id (i + 1))
      | _ -> gen_id i
  in
  let id = (gen_id 0) in
  if Db.user_id_exists id
    then create_user_id ()
    else id ;;

let response_of_create response = 
  let make_json inner = 
    `Assoc [("CreateResponse", inner)] in
  let inner_data = 
    match response with
      | CreateID id -> `Assoc [("id", `String id)]
      | CreateError e -> `Assoc [("error", `String e)] 
  in
  make_json inner_data ;;

let write_json_to_client io (response : Yj.json) =
  let oc = (snd io) in
  let data = Yj.to_string response in 
  let len = Int32.of_int @@ String.length data in
  Lwt_io.BE.write_int32 oc len
  >>= (fun () -> Lwt_io.write oc data)
  >>= (fun () -> Lwt_io.printf "OUT: %s (%ld)\n" data len)
  >>= (fun () -> Lwt_io.flush oc) ;;

let json_id_exists jsonl = 
  let id = Yj.Util.to_string @@ List.assoc "id" jsonl in
  Db.user_id_exists id ;;

let verify_query = function 
  | ValidQuery q -> 
      if Db.user_id_exists q.id 
      then ValidQuery q 
      else InvalidQuery
  | _ -> InvalidQuery ;;

let api_main io = function
  | Update j ->
      return @@ update_of_json j
      >>= write_update
      >|= string_of_update
      >>= printl
  | Query j -> 
      return @@ query_of_json j 
      >|= verify_query
      >>= (function
        | InvalidQuery -> return @@ Const.default_query_response
        | ValidQuery q -> 
            (return @@ query_main io q
            >|= response_json_of_query))
      >>= write_json_to_client io
  | Create j -> 
      return @@ create_of_json j 
      >|= verify_create_data
      >>= (function
        | InvalidCreate why -> return @@ CreateError why
        | ValidCreate d -> 
            (let id = create_user_id () in
            return @@ write_create d id
            >|= (fun () -> CreateID id)))
      >|= response_of_create
      >>= write_json_to_client io ;;

let server_main io =
  let in_chan,out_chan = io in
  let read_json ch len = 
    Lwt_io.read ~count:len ch
    >>= (fun j -> Lwt_io.printf "IN:  %s\n" j 
    >|= (fun () -> j)) in
  Lwt_io.BE.read_int in_chan
  >|= verify_request_length 
  >>= read_json in_chan
  >|= Yj.from_string
  >|= api_of_json 
  >>= api_main io ;;

let background_tasks () = 
  let too_old = 
    Int64.sub (Unix.time_int64 ()) Const.stale_db_entry_time in
  Lwt_io.printf "Removing older than %Ld\n" too_old
  >|= (fun () -> Db.delete_older_than too_old) ;;

let rec sleepy_loop delay = 
  Lwt_unix.sleep delay
  >>= (fun () -> background_tasks ())
  >>= (fun () -> sleepy_loop delay) ;;

let start_server io = 
  let log_stop_server msg = 
    let in_chan,out_chan = io in
    Lwt_io.printl msg
    >>= (fun () -> Lwt_io.close out_chan)
    >>= (fun () -> Lwt_io.close in_chan) in
  let start_server () = 
    Lwt.catch 
      (fun () -> 
        server_main io
        >>= (fun () -> Lwt_io.close (fst io))
        >>= (fun () -> Lwt_io.close (snd io)))
      (function                    (* Where fatal errors are caught *)
        | Err s -> 
            log_stop_server ("Error: " ^ s)
        | Sqlite3.Error msg -> 
            log_stop_server (sprintf "Sqlite3.Error: %s" msg)
        | Yojson.Json_error msg -> 
            log_stop_server (sprintf "Json_error: %s" msg)
        | Yj.Util.Type_error (msg,json) ->
            log_stop_server (sprintf "Type_error: %s (json = %s)" msg (Yj.to_string json))
        | e -> raise e) 
  in
  Lwt.async start_server ;;

let main () =
  let listen_addr = Unix.ADDR_INET (Unix.inet_addr_any, Const.port) in
  Lwt_io.print @@ Location.string_of_location_conf Const.location_config
  >>= (fun () -> Lwt_io.printf "Started server on port %d\n" Const.port)
  >|= Db.reset_db
  >>= (fun () ->
    Lwt.async 
    begin fun () -> 
      return @@ 
        Lwt_io.establish_server 
        ~backlog:Const.backlog
        ~buffer_size:Const.buffer_size
        listen_addr
        start_server
    end ;
    sleepy_loop Const.sleepy_loop_delay) ;;

Random.self_init ();
Printexc.record_backtrace true ;;
Lwt_main.run @@ main () ;;
