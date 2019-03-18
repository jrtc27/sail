(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*    Brian Campbell                                                      *)
(*    Thomas Bauereiss                                                    *)
(*    Anthony Fox                                                         *)
(*    Jon French                                                          *)
(*    Dominic Mulligan                                                    *)
(*    Stephen Kell                                                        *)
(*    Mark Wassell                                                        *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open Ast
open Ast_util
open Jib
open Jib_compile
open Jib_util
open Type_check
open PPrint
open Value2

open Anf

module Big_int = Nat_big_num

let c_verbosity = ref 0

let opt_static = ref false
let opt_no_main = ref false
let opt_memo_cache = ref false
let opt_no_rts = ref false
let opt_prefix = ref "z"
let opt_extra_params = ref None
let opt_extra_arguments = ref None

let extra_params () =
  match !opt_extra_params with
  | Some str -> str ^ ", "
  | _ -> ""

let extra_arguments is_extern =
  match !opt_extra_arguments with
  | Some str when not is_extern -> str ^ ", "
  | _ -> ""

(* Optimization flags *)
let optimize_primops = ref false
let optimize_hoist_allocations = ref false
let optimize_struct_updates = ref false
let optimize_alias = ref false
let optimize_experimental = ref false

let c_debug str =
  if !c_verbosity > 0 then prerr_endline (Lazy.force str) else ()

let c_error ?loc:(l=Parse_ast.Unknown) message =
  raise (Reporting.err_general l ("\nC backend: " ^ message))

let zencode_id = function
  | Id_aux (Id str, l) -> Id_aux (Id (Util.zencode_string str), l)
  | Id_aux (DeIid str, l) -> Id_aux (Id (Util.zencode_string ("op " ^ str)), l)

(**************************************************************************)
(* 2. Converting sail types to C types                                    *)
(**************************************************************************)

let max_int n = Big_int.pred (Big_int.pow_int_positive 2 (n - 1))
let min_int n = Big_int.negate (Big_int.pow_int_positive 2 (n - 1))

(** Convert a sail type into a C-type. This function can be quite
   slow, because it uses ctx.local_env and SMT to analyse the Sail
   types and attempts to fit them into the smallest possible C
   types, provided ctx.optimize_smt is true (default) **)
let rec ctyp_of_typ ctx typ =
  let Typ_aux (typ_aux, l) as typ = Env.expand_synonyms ctx.tc_env typ in
  match typ_aux with
  | Typ_id id when string_of_id id = "bit"    -> CT_bit
  | Typ_id id when string_of_id id = "bool"   -> CT_bool
  | Typ_id id when string_of_id id = "int"    -> CT_lint
  | Typ_id id when string_of_id id = "nat"    -> CT_lint
  | Typ_id id when string_of_id id = "unit"   -> CT_unit
  | Typ_id id when string_of_id id = "string" -> CT_string
  | Typ_id id when string_of_id id = "real"   -> CT_real

  | Typ_app (id, _) when string_of_id id = "atom_bool" -> CT_bool

  | Typ_app (id, args) when string_of_id id = "itself" ->
     ctyp_of_typ ctx (Typ_aux (Typ_app (mk_id "atom", args), l))
  | Typ_app (id, _) when string_of_id id = "range" || string_of_id id = "atom" || string_of_id id = "implicit" ->
     begin match destruct_range Env.empty typ with
     | None -> assert false (* Checked if range type in guard *)
     | Some (kids, constr, n, m) ->
        let ctx = { ctx with local_env = add_existential Parse_ast.Unknown (List.map (mk_kopt K_int) kids) constr ctx.local_env } in
        match nexp_simp n, nexp_simp m with
        | Nexp_aux (Nexp_constant n, _), Nexp_aux (Nexp_constant m, _)
             when Big_int.less_equal (min_int 64) n && Big_int.less_equal m (max_int 64) ->
           CT_fint 64
        | n, m ->
           if prove __POS__ ctx.local_env (nc_lteq (nconstant (min_int 64)) n) && prove __POS__ ctx.local_env (nc_lteq m (nconstant (max_int 64))) then
             CT_fint 64
           else
             CT_lint
     end

  | Typ_app (id, [A_aux (A_typ typ, _)]) when string_of_id id = "list" ->
     CT_list (ctyp_of_typ ctx typ)

  (* When converting a sail bitvector type into C, we have three options in order of efficiency:
     - If the length is obviously static and smaller than 64, use the fixed bits type (aka uint64_t), fbits.
     - If the length is less than 64, then use a small bits type, sbits.
     - If the length may be larger than 64, use a large bits type lbits. *)
  | Typ_app (id, [A_aux (A_nexp n, _);
                  A_aux (A_order ord, _);
                  A_aux (A_typ (Typ_aux (Typ_id vtyp_id, _)), _)])
       when string_of_id id = "vector" && string_of_id vtyp_id = "bit" ->
     let direction = match ord with Ord_aux (Ord_dec, _) -> true | Ord_aux (Ord_inc, _) -> false | _ -> assert false in
     begin match nexp_simp n with
     | Nexp_aux (Nexp_constant n, _) when Big_int.less_equal n (Big_int.of_int 64) -> CT_fbits (Big_int.to_int n, direction)
     | n when prove __POS__ ctx.local_env (nc_lteq n (nint 64)) -> CT_sbits (64, direction)
     | _ -> CT_lbits direction
     end

  | Typ_app (id, [A_aux (A_nexp n, _);
                  A_aux (A_order ord, _);
                  A_aux (A_typ typ, _)])
       when string_of_id id = "vector" ->
     let direction = match ord with Ord_aux (Ord_dec, _) -> true | Ord_aux (Ord_inc, _) -> false | _ -> assert false in
     CT_vector (direction, ctyp_of_typ ctx typ)

  | Typ_app (id, [A_aux (A_typ typ, _)]) when string_of_id id = "register" ->
     CT_ref (ctyp_of_typ ctx typ)

  | Typ_id id | Typ_app (id, _) when Bindings.mem id ctx.records  -> CT_struct (id, Bindings.find id ctx.records |> Bindings.bindings)
  | Typ_id id | Typ_app (id, _) when Bindings.mem id ctx.variants -> CT_variant (id, Bindings.find id ctx.variants |> Bindings.bindings)
  | Typ_id id when Bindings.mem id ctx.enums -> CT_enum (id, Bindings.find id ctx.enums |> IdSet.elements)

  | Typ_tup typs -> CT_tup (List.map (ctyp_of_typ ctx) typs)

  | Typ_exist _ ->
     (* Use Type_check.destruct_exist when optimising with SMT, to
        ensure that we don't cause any type variable clashes in
        local_env, and that we can optimize the existential based upon
        it's constraints. *)
     begin match destruct_exist (Env.expand_synonyms ctx.local_env typ) with
     | Some (kids, nc, typ) ->
        let env = add_existential l kids nc ctx.local_env in
        ctyp_of_typ { ctx with local_env = env } typ
     | None -> raise (Reporting.err_unreachable l __POS__ "Existential cannot be destructured!")
     end

  | Typ_var kid -> CT_poly

  | _ -> c_error ~loc:l ("No C type for type " ^ string_of_typ typ)

let rec is_stack_ctyp ctyp = match ctyp with
  | CT_fbits _ | CT_sbits _ | CT_bit | CT_unit | CT_bool | CT_enum _ -> true
  | CT_fint n -> n <= 64
  | CT_lbits _ | CT_lint | CT_real | CT_string | CT_list _ | CT_vector _ -> false
  | CT_struct (_, fields) -> List.for_all (fun (_, ctyp) -> is_stack_ctyp ctyp) fields
  | CT_variant (_, ctors) -> false (* List.for_all (fun (_, ctyp) -> is_stack_ctyp ctyp) ctors *) (* FIXME *)
  | CT_tup ctyps -> List.for_all is_stack_ctyp ctyps
  | CT_ref ctyp -> true
  | CT_poly -> true

let is_stack_typ ctx typ = is_stack_ctyp (ctyp_of_typ ctx typ)

let is_fbits_typ ctx typ =
  match ctyp_of_typ ctx typ with
  | CT_fbits _ -> true
  | _ -> false

let is_sbits_typ ctx typ =
  match ctyp_of_typ ctx typ with
  | CT_sbits _ -> true
  | _ -> false

let ctor_bindings = List.fold_left (fun map (id, ctyp) -> Bindings.add id ctyp map) Bindings.empty

(**************************************************************************)
(* 3. Optimization of primitives and literals                             *)
(**************************************************************************)

let hex_char =
  let open Sail2_values in
  function
  | '0' -> [B0; B0; B0; B0]
  | '1' -> [B0; B0; B0; B1]
  | '2' -> [B0; B0; B1; B0]
  | '3' -> [B0; B0; B1; B1]
  | '4' -> [B0; B1; B0; B0]
  | '5' -> [B0; B1; B0; B1]
  | '6' -> [B0; B1; B1; B0]
  | '7' -> [B0; B1; B1; B1]
  | '8' -> [B1; B0; B0; B0]
  | '9' -> [B1; B0; B0; B1]
  | 'A' | 'a' -> [B1; B0; B1; B0]
  | 'B' | 'b' -> [B1; B0; B1; B1]
  | 'C' | 'c' -> [B1; B1; B0; B0]
  | 'D' | 'd' -> [B1; B1; B0; B1]
  | 'E' | 'e' -> [B1; B1; B1; B0]
  | 'F' | 'f' -> [B1; B1; B1; B1]
  | _ -> failwith "Invalid hex character"

let literal_to_fragment (L_aux (l_aux, _) as lit) =
  match l_aux with
  | L_num n when Big_int.less_equal (min_int 64) n && Big_int.less_equal n (max_int 64) ->
     Some (F_lit (V_int n), CT_fint 64)
  | L_hex str when String.length str <= 16 ->
     let padding = 16 - String.length str in
     let padding = Util.list_init padding (fun _ -> Sail2_values.B0) in
     let content = Util.string_to_list str |> List.map hex_char |> List.concat in
     Some (F_lit (V_bits (padding @ content)), CT_fbits (String.length str * 4, true))
  | L_unit -> Some (F_lit V_unit, CT_unit)
  | L_true -> Some (F_lit (V_bool true), CT_bool)
  | L_false -> Some (F_lit (V_bool false), CT_bool)
  | _ -> None

let c_literals ctx =
  let rec c_literal env l = function
    | AV_lit (lit, typ) as v when is_stack_ctyp (ctyp_of_typ { ctx with local_env = env } typ) ->
       begin
         match literal_to_fragment lit with
         | Some (frag, ctyp) -> AV_C_fragment (frag, typ, ctyp)
         | None -> v
       end
    | AV_tuple avals -> AV_tuple (List.map (c_literal env l) avals)
    | v -> v
  in
  map_aval c_literal

let mask m =
  if Big_int.less_equal m (Big_int.of_int 64) then
    let n = Big_int.to_int m in
    if n = 0 then
      "UINT64_C(0)"
    else if n mod 4 = 0 then
      "UINT64_C(0x" ^ String.make (16 - n / 4) '0' ^ String.make (n / 4) 'F' ^ ")"
    else
      "UINT64_C(" ^ String.make (64 - n) '0' ^ String.make n '1' ^ ")"
  else
    failwith "Tried to create a mask literal for a vector greater than 64 bits."

let rec is_bitvector = function
  | [] -> true
  | AV_lit (L_aux (L_zero, _), _) :: avals -> is_bitvector avals
  | AV_lit (L_aux (L_one, _), _) :: avals -> is_bitvector avals
  | _ :: _ -> false

let rec value_of_aval_bit = function
  | AV_lit (L_aux (L_zero, _), _) -> Sail2_values.B0
  | AV_lit (L_aux (L_one, _), _) -> Sail2_values.B1
  | _ -> assert false

let rec c_aval ctx = function
  | AV_lit (lit, typ) as v ->
     begin
       match literal_to_fragment lit with
       | Some (frag, ctyp) -> AV_C_fragment (frag, typ, ctyp)
       | None -> v
     end
  | AV_C_fragment (str, typ, ctyp) -> AV_C_fragment (str, typ, ctyp)
  (* An id can be converted to a C fragment if it's type can be
     stack-allocated. *)
  | AV_id (id, lvar) as v ->
     begin
       match lvar with
       | Local (_, typ) ->
          let ctyp = ctyp_of_typ ctx typ in
          if is_stack_ctyp ctyp then
            begin
              try
                (* We need to check that id's type hasn't changed due to flow typing *)
                let _, ctyp' = Bindings.find id ctx.locals in
                if ctyp_equal ctyp ctyp' then
                  AV_C_fragment (F_id (name id), typ, ctyp)
                else
                  (* id's type changed due to flow
                     typing, so it's really still heap allocated!  *)
                  v
              with
                (* Hack: Assuming global letbindings don't change from flow typing... *)
                Not_found -> AV_C_fragment (F_id (name id), typ, ctyp)
            end
          else
            v
       | Register (_, _, typ) when is_stack_typ ctx typ ->
          let ctyp = ctyp_of_typ ctx typ in
          if is_stack_ctyp ctyp then
            AV_C_fragment (F_id (name id), typ, ctyp)
          else
            v
       | _ -> v
     end
  | AV_vector (v, typ) when is_bitvector v && List.length v <= 64 ->
     let bitstring = F_lit (V_bits (List.map value_of_aval_bit v)) in
     AV_C_fragment (bitstring, typ, CT_fbits (List.length v, true))
  | AV_tuple avals -> AV_tuple (List.map (c_aval ctx) avals)
  | aval -> aval

let is_c_fragment = function
  | AV_C_fragment _ -> true
  | _ -> false

let c_fragment = function
  | AV_C_fragment (frag, _, _) -> frag
  | _ -> assert false

let v_mask_lower i = F_lit (V_bits (Util.list_init i (fun _ -> Sail2_values.B1)))

(* Map over all the functions in an aexp. *)
let rec analyze_functions ctx f (AE_aux (aexp, env, l)) =
  let ctx = { ctx with local_env = env } in
  let aexp = match aexp with
    | AE_app (id, vs, typ) -> f ctx id vs typ

    | AE_cast (aexp, typ) -> AE_cast (analyze_functions ctx f aexp, typ)

    | AE_assign (id, typ, aexp) -> AE_assign (id, typ, analyze_functions ctx f aexp)

    | AE_short_circuit (op, aval, aexp) -> AE_short_circuit (op, aval, analyze_functions ctx f aexp)

    | AE_let (mut, id, typ1, aexp1, (AE_aux (_, env2, _) as aexp2), typ2) ->
       let aexp1 = analyze_functions ctx f aexp1 in
       (* Use aexp2's environment because it will contain constraints for id *)
       let ctyp1 = ctyp_of_typ { ctx with local_env = env2 } typ1 in
       let ctx = { ctx with locals = Bindings.add id (mut, ctyp1) ctx.locals } in
       AE_let (mut, id, typ1, aexp1, analyze_functions ctx f aexp2, typ2)

    | AE_block (aexps, aexp, typ) -> AE_block (List.map (analyze_functions ctx f) aexps, analyze_functions ctx f aexp, typ)

    | AE_if (aval, aexp1, aexp2, typ) ->
       AE_if (aval, analyze_functions ctx f aexp1, analyze_functions ctx f aexp2, typ)

    | AE_loop (loop_typ, aexp1, aexp2) -> AE_loop (loop_typ, analyze_functions ctx f aexp1, analyze_functions ctx f aexp2)

    | AE_for (id, aexp1, aexp2, aexp3, order, aexp4) ->
       let aexp1 = analyze_functions ctx f aexp1 in
       let aexp2 = analyze_functions ctx f aexp2 in
       let aexp3 = analyze_functions ctx f aexp3 in
       let aexp4 = analyze_functions ctx f aexp4 in
       (* Currently we assume that loop indexes are always safe to put into an int64 *)
       let ctx = { ctx with locals = Bindings.add id (Immutable, CT_fint 64) ctx.locals } in
       AE_for (id, aexp1, aexp2, aexp3, order, aexp4)

    | AE_case (aval, cases, typ) ->
       let analyze_case (AP_aux (_, env, _) as pat, aexp1, aexp2) =
         let pat_bindings = Bindings.bindings (apat_types pat) in
         let ctx = { ctx with local_env = env } in
         let ctx =
           List.fold_left (fun ctx (id, typ) -> { ctx with locals = Bindings.add id (Immutable, ctyp_of_typ ctx typ) ctx.locals }) ctx pat_bindings
         in
         pat, analyze_functions ctx f aexp1, analyze_functions ctx f aexp2
       in
       AE_case (aval, List.map analyze_case cases, typ)

    | AE_try (aexp, cases, typ) ->
       AE_try (analyze_functions ctx f aexp, List.map (fun (pat, aexp1, aexp2) -> pat, analyze_functions ctx f aexp1, analyze_functions ctx f aexp2) cases, typ)

    | AE_field _ | AE_record_update _ | AE_val _ | AE_return _ | AE_throw _ as v -> v
  in
  AE_aux (aexp, env, l)

let analyze_primop' ctx id args typ =
  let no_change = AE_app (id, args, typ) in
  let args = List.map (c_aval ctx) args in
  let extern = if Env.is_extern id ctx.tc_env "c" then Env.get_extern id ctx.tc_env "c" else failwith "Not extern" in

  let v_one = F_lit (V_int (Big_int.of_int 1)) in
  let v_int n = F_lit (V_int (Big_int.of_int n)) in

  c_debug (lazy ("Analyzing primop " ^ extern ^ "(" ^ Util.string_of_list ", " (fun aval -> Pretty_print_sail.to_string (pp_aval aval)) args ^ ")"));

  match extern, args with
  | "eq_bits", [AV_C_fragment (v1, _, CT_fbits _); AV_C_fragment (v2, _, _)] ->
     AE_val (AV_C_fragment (F_op (v1, "==", v2), typ, CT_bool))
  | "eq_bits", [AV_C_fragment (v1, _, CT_sbits _); AV_C_fragment (v2, _, _)] ->
     AE_val (AV_C_fragment (F_call ("eq_sbits", [v1; v2]), typ, CT_bool))

  | "neq_bits", [AV_C_fragment (v1, _, CT_fbits _); AV_C_fragment (v2, _, _)] ->
     AE_val (AV_C_fragment (F_op (v1, "!=", v2), typ, CT_bool))
  | "neq_bits", [AV_C_fragment (v1, _, CT_sbits _); AV_C_fragment (v2, _, _)] ->
     AE_val (AV_C_fragment (F_call ("neq_sbits", [v1; v2]), typ, CT_bool))

  | "eq_int", [AV_C_fragment (v1, typ1, _); AV_C_fragment (v2, typ2, _)] ->
     AE_val (AV_C_fragment (F_op (v1, "==", v2), typ, CT_bool))

  | "zeros", [_] ->
     begin match destruct_vector ctx.tc_env typ with
     | Some (Nexp_aux (Nexp_constant n, _), _, Typ_aux (Typ_id id, _))
          when string_of_id id = "bit" && Big_int.less_equal n (Big_int.of_int 64) ->
        AE_val (AV_C_fragment (F_raw "0x0", typ, CT_fbits (Big_int.to_int n, true)))
     | _ -> no_change
     end

  | "zero_extend", [AV_C_fragment (v1, _, CT_fbits _); _] ->
     begin match destruct_vector ctx.tc_env typ with
     | Some (Nexp_aux (Nexp_constant n, _), _, Typ_aux (Typ_id id, _))
          when string_of_id id = "bit" && Big_int.less_equal n (Big_int.of_int 64) ->
        AE_val (AV_C_fragment (v1, typ, CT_fbits (Big_int.to_int n, true)))
     | _ -> no_change
     end

  | "zero_extend", [AV_C_fragment (v1, _, CT_sbits _); _] ->
     begin match destruct_vector ctx.tc_env typ with
     | Some (Nexp_aux (Nexp_constant n, _), _, Typ_aux (Typ_id id, _))
          when string_of_id id = "bit" && Big_int.less_equal n (Big_int.of_int 64) ->
        AE_val (AV_C_fragment (F_call ("fast_zero_extend", [v1; v_int (Big_int.to_int n)]), typ, CT_fbits (Big_int.to_int n, true)))
     | _ -> no_change
     end

  | "sign_extend", [AV_C_fragment (v1, _, CT_fbits (n, _)); _] ->
     begin match destruct_vector ctx.tc_env typ with
     | Some (Nexp_aux (Nexp_constant m, _), _, Typ_aux (Typ_id id, _))
          when string_of_id id = "bit" && Big_int.less_equal m (Big_int.of_int 64) ->
        AE_val (AV_C_fragment (F_call ("fast_sign_extend", [v1; v_int n; v_int (Big_int.to_int m)]) , typ, CT_fbits (Big_int.to_int m, true)))
     | _ -> no_change
     end

  | "sign_extend", [AV_C_fragment (v1, _, CT_sbits _); _] ->
     begin match destruct_vector ctx.tc_env typ with
     | Some (Nexp_aux (Nexp_constant m, _), _, Typ_aux (Typ_id id, _))
          when string_of_id id = "bit" && Big_int.less_equal m (Big_int.of_int 64) ->
        AE_val (AV_C_fragment (F_call ("fast_sign_extend2", [v1; v_int (Big_int.to_int m)]) , typ, CT_fbits (Big_int.to_int m, true)))
     | _ -> no_change
     end

  | "add_bits", [AV_C_fragment (v1, _, CT_fbits (n, ord)); AV_C_fragment (v2, _, CT_fbits _)]
       when n <= 63 ->
     AE_val (AV_C_fragment (F_op (F_op (v1, "+", v2), "&", v_mask_lower n), typ, CT_fbits (n, ord)))

  | "lteq", [AV_C_fragment (v1, _, _); AV_C_fragment (v2, _, _)] ->
     AE_val (AV_C_fragment (F_op (v1, "<=", v2), typ, CT_bool))
  | "gteq", [AV_C_fragment (v1, _, _); AV_C_fragment (v2, _, _)] ->
     AE_val (AV_C_fragment (F_op (v1, ">=", v2), typ, CT_bool))
  | "lt", [AV_C_fragment (v1, _, _); AV_C_fragment (v2, _, _)] ->
     AE_val (AV_C_fragment (F_op (v1, "<", v2), typ, CT_bool))
  | "gt", [AV_C_fragment (v1, _, _); AV_C_fragment (v2, _, _)] ->
     AE_val (AV_C_fragment (F_op (v1, ">", v2), typ, CT_bool))

  | "xor_bits", [AV_C_fragment (v1, _, (CT_fbits _ as ctyp)); AV_C_fragment (v2, _, CT_fbits _)] ->
     AE_val (AV_C_fragment (F_op (v1, "^", v2), typ, ctyp))
  | "xor_bits", [AV_C_fragment (v1, _, (CT_sbits _ as ctyp)); AV_C_fragment (v2, _, CT_sbits _)] ->
     AE_val (AV_C_fragment (F_call ("xor_sbits", [v1; v2]), typ, ctyp))

  | "or_bits", [AV_C_fragment (v1, _, (CT_fbits _ as ctyp)); AV_C_fragment (v2, _, CT_fbits _)] ->
     AE_val (AV_C_fragment (F_op (v1, "|", v2), typ, ctyp))

  | "and_bits", [AV_C_fragment (v1, _, (CT_fbits _ as ctyp)); AV_C_fragment (v2, _, CT_fbits _)] ->
     AE_val (AV_C_fragment (F_op (v1, "&", v2), typ, ctyp))

  | "not_bits", [AV_C_fragment (v, _, ctyp)] ->
     begin match destruct_vector ctx.tc_env typ with
     | Some (Nexp_aux (Nexp_constant n, _), _, Typ_aux (Typ_id id, _))
          when string_of_id id = "bit" && Big_int.less_equal n (Big_int.of_int 64) ->
        AE_val (AV_C_fragment (F_op (F_unary ("~", v), "&", v_mask_lower (Big_int.to_int n)), typ, ctyp))
     | _ -> no_change
     end

  | "vector_subrange", [AV_C_fragment (vec, _, CT_fbits _); AV_C_fragment (f, _, _); AV_C_fragment (t, _, _)]
       when is_fbits_typ ctx typ ->
     let len = F_op (f, "-", F_op (t, "-", v_one)) in
     AE_val (AV_C_fragment (F_op (F_call ("safe_rshift", [F_raw "UINT64_MAX"; F_op (v_int 64, "-", len)]), "&", F_op (vec, ">>", t)),
                            typ,
                            ctyp_of_typ ctx typ))

  | "vector_access", [AV_C_fragment (vec, _, CT_fbits _); AV_C_fragment (n, _, _)] ->
     AE_val (AV_C_fragment (F_op (v_one, "&", F_op (vec, ">>", n)), typ, CT_bit))

  | "eq_bit", [AV_C_fragment (a, _, _); AV_C_fragment (b, _, _)] ->
     AE_val (AV_C_fragment (F_op (a, "==", b), typ, CT_bool))

  | "slice", [AV_C_fragment (vec, _, CT_fbits _); AV_C_fragment (start, _, _); AV_C_fragment (len, _, _)]
       when is_fbits_typ ctx typ ->
     AE_val (AV_C_fragment (F_op (F_call ("safe_rshift", [F_raw "UINT64_MAX"; F_op (v_int 64, "-", len)]), "&", F_op (vec, ">>", start)),
                            typ,
                            ctyp_of_typ ctx typ))

  | "slice", [AV_C_fragment (vec, _, CT_fbits _); AV_C_fragment (start, _, _); AV_C_fragment (len, _, _)]
       when is_sbits_typ ctx typ ->
     AE_val (AV_C_fragment (F_call ("sslice", [vec; start; len]), typ, ctyp_of_typ ctx typ))

  | "undefined_bit", _ ->
     AE_val (AV_C_fragment (F_lit (V_bit Sail2_values.B0), typ, CT_bit))

  (* Optimized routines for all combinations of fixed and small bits
     appends, where the result is guaranteed to be smaller than 64. *)
  | "append", [AV_C_fragment (vec1, _, CT_fbits (0, ord1)); AV_C_fragment (vec2, _, CT_fbits (n2, ord2)) as v2]
       when ord1 = ord2 ->
     AE_val v2
  | "append", [AV_C_fragment (vec1, _, CT_fbits (n1, ord1)); AV_C_fragment (vec2, _, CT_fbits (n2, ord2))]
       when ord1 = ord2 && n1 + n2 <= 64 ->
     AE_val (AV_C_fragment (F_op (F_op (vec1, "<<", v_int n2), "|", vec2), typ, CT_fbits (n1 + n2, ord1)))

  | "append", [AV_C_fragment (vec1, _, CT_sbits (64, ord1)); AV_C_fragment (vec2, _, CT_fbits (n2, ord2))]
       when ord1 = ord2 && is_sbits_typ ctx typ ->
     AE_val (AV_C_fragment (F_call ("append_sf", [vec1; vec2; v_int n2]), typ, ctyp_of_typ ctx typ))

  | "append", [AV_C_fragment (vec1, _, CT_fbits (n1, ord1)); AV_C_fragment (vec2, _, CT_sbits (64, ord2))]
       when ord1 = ord2 && is_sbits_typ ctx typ ->
     AE_val (AV_C_fragment (F_call ("append_fs", [vec1; v_int n1; vec2]), typ, ctyp_of_typ ctx typ))

  | "append", [AV_C_fragment (vec1, _, CT_sbits (64, ord1)); AV_C_fragment (vec2, _, CT_sbits (64, ord2))]
       when ord1 = ord2 && is_sbits_typ ctx typ ->
     AE_val (AV_C_fragment (F_call ("append_ss", [vec1; vec2]), typ, ctyp_of_typ ctx typ))

  | "undefined_vector", [AV_C_fragment (len, _, _); _] ->
     begin match destruct_vector ctx.tc_env typ with
     | Some (Nexp_aux (Nexp_constant n, _), _, Typ_aux (Typ_id id, _))
          when string_of_id id = "bit" && Big_int.less_equal n (Big_int.of_int 64) ->
       AE_val (AV_C_fragment (F_lit (V_bit Sail2_values.B0), typ, ctyp_of_typ ctx typ))
     | _ -> no_change
     end

  | "sail_unsigned", [AV_C_fragment (frag, vtyp, _)] ->
     begin match destruct_vector ctx.tc_env vtyp with
     | Some (Nexp_aux (Nexp_constant n, _), _, _)
          when Big_int.less_equal n (Big_int.of_int 63) && is_stack_typ ctx typ ->
        AE_val (AV_C_fragment (F_call ("fast_unsigned", [frag]), typ, ctyp_of_typ ctx typ))
     | _ -> no_change
     end

  | "sail_signed", [AV_C_fragment (frag, vtyp, _)] ->
     begin match destruct_vector ctx.tc_env vtyp with
     | Some (Nexp_aux (Nexp_constant n, _), _, _)
          when Big_int.less_equal n (Big_int.of_int 64) && is_stack_typ ctx typ ->
        AE_val (AV_C_fragment (F_call ("fast_signed", [frag; v_int (Big_int.to_int n)]), typ, ctyp_of_typ ctx typ))
     | _ -> no_change
     end

  | "add_int", [AV_C_fragment (op1, _, _); AV_C_fragment (op2, _, _)] ->
     begin match destruct_range Env.empty typ with
     | None -> no_change
     | Some (kids, constr, n, m) ->
        match nexp_simp n, nexp_simp m with
        | Nexp_aux (Nexp_constant n, _), Nexp_aux (Nexp_constant m, _)
               when Big_int.less_equal (min_int 64) n && Big_int.less_equal m (max_int 64) ->
           AE_val (AV_C_fragment (F_op (op1, "+", op2), typ, CT_fint 64))
        | n, m when prove __POS__ ctx.local_env (nc_lteq (nconstant (min_int 64)) n) && prove __POS__ ctx.local_env (nc_lteq m (nconstant (max_int 64))) ->
           AE_val (AV_C_fragment (F_op (op1, "+", op2), typ, CT_fint 64))
        | _ -> no_change
     end

  | "neg_int", [AV_C_fragment (frag, _, _)] ->
     AE_val (AV_C_fragment (F_op (v_int 0, "-", frag), typ, CT_fint 64))

  | "replicate_bits", [AV_C_fragment (vec, vtyp, _); AV_C_fragment (times, _, _)] ->
     begin match destruct_vector ctx.tc_env typ, destruct_vector ctx.tc_env vtyp with
     | Some (Nexp_aux (Nexp_constant n, _), _, _), Some (Nexp_aux (Nexp_constant m, _), _, _)
          when Big_int.less_equal n (Big_int.of_int 64) ->
        AE_val (AV_C_fragment (F_call ("fast_replicate_bits", [F_lit (V_int m); vec; times]), typ, ctyp_of_typ ctx typ))
     | _ -> no_change
     end

  | "vector_update_subrange", [AV_C_fragment (xs, _, CT_fbits (n, true));
                               AV_C_fragment (hi, _, CT_fint 64);
                               AV_C_fragment (lo, _, CT_fint 64);
                               AV_C_fragment (ys, _, CT_fbits (m, true))] ->
     AE_val (AV_C_fragment (F_call ("fast_update_subrange", [xs; hi; lo; ys]), typ, CT_fbits (n, true)))

  | "undefined_bool", _ ->
     AE_val (AV_C_fragment (F_lit (V_bool false), typ, CT_bool))

  | _, _ ->
     c_debug (lazy ("No optimization routine found"));
     no_change

let analyze_primop ctx id args typ =
  let no_change = AE_app (id, args, typ) in
  if !optimize_primops then
    try analyze_primop' ctx id args typ with
    | Failure str ->
       (c_debug (lazy ("Analyze primop failed for id " ^ string_of_id id ^ " reason: " ^ str)));
       no_change
  else
    no_change

(** Functions that have heap-allocated return types are implemented by
   passing a pointer a location where the return value should be
   stored. The ANF -> Sail IR pass for expressions simply outputs an
   I_return instruction for any return value, so this function walks
   over the IR ast for expressions and modifies the return statements
   into code that sets that pointer, as well as adds extra control
   flow to cleanup heap-allocated variables correctly when a function
   terminates early. See the generate_cleanup function for how this is
   done. *)
let fix_early_heap_return ret ret_ctyp instrs =
  let end_function_label = label "end_function_" in
  let is_return_recur (I_aux (instr, _)) =
    match instr with
    | I_if _ | I_block _ | I_end | I_funcall _ | I_copy _ | I_undefined _ -> true
    | _ -> false
  in
  let rec rewrite_return instrs =
    match instr_split_at is_return_recur instrs with
    | instrs, [] -> instrs
    | before, I_aux (I_block instrs, _) :: after ->
       before
       @ [iblock (rewrite_return instrs)]
       @ rewrite_return after
    | before, I_aux (I_if (cval, then_instrs, else_instrs, ctyp), _) :: after ->
       before
       @ [iif cval (rewrite_return then_instrs) (rewrite_return else_instrs) ctyp]
       @ rewrite_return after
    | before, I_aux (I_funcall (CL_id (Return _, ctyp), extern, fid, args), aux) :: after ->
       before
       @ [I_aux (I_funcall (CL_addr (CL_id (ret, CT_ref ctyp)), extern, fid, args), aux)]
       @ rewrite_return after
    | before, I_aux (I_copy (CL_id (Return _, ctyp), cval), aux) :: after ->
       before
       @ [I_aux (I_copy (CL_addr (CL_id (ret, CT_ref ctyp)), cval), aux)]
       @ rewrite_return after
    | before, I_aux ((I_end | I_undefined _), _) :: after ->
       before
       @ [igoto end_function_label]
       @ rewrite_return after
    | before, (I_aux ((I_copy _ | I_funcall _), _) as instr) :: after ->
       before @ instr :: rewrite_return after
    | _, _ -> assert false
  in
  rewrite_return instrs
  @ [ilabel end_function_label]

(* This is like fix_early_return, but for stack allocated returns. *)
let fix_early_stack_return ret ret_ctyp instrs =
  let is_return_recur (I_aux (instr, _)) =
    match instr with
    | I_if _ | I_block _ | I_end | I_funcall _ | I_copy _ -> true
    | _ -> false
  in
  let rec rewrite_return instrs =
    match instr_split_at is_return_recur instrs with
    | instrs, [] -> instrs
    | before, I_aux (I_block instrs, _) :: after ->
       before
       @ [iblock (rewrite_return instrs)]
       @ rewrite_return after
    | before, I_aux (I_if (cval, then_instrs, else_instrs, ctyp), _) :: after ->
       before
       @ [iif cval (rewrite_return then_instrs) (rewrite_return else_instrs) ctyp]
       @ rewrite_return after
    | before, I_aux (I_funcall (CL_id (Return _, ctyp), extern, fid, args), aux) :: after ->
       before
       @ [I_aux (I_funcall (CL_id (ret, ctyp), extern, fid, args), aux)]
       @ rewrite_return after
    | before, I_aux (I_copy (CL_id (Return _, ctyp), cval), aux) :: after ->
       before
       @ [I_aux (I_copy (CL_id (ret, ctyp), cval), aux)]
       @ rewrite_return after
    | before, I_aux (I_end, _) :: after ->
       before
       @ [ireturn (F_id ret, ret_ctyp)]
       @ rewrite_return after
    | before, (I_aux ((I_copy _ | I_funcall _), _) as instr) :: after ->
       before @ instr :: rewrite_return after
    | _, _ -> assert false
  in
  rewrite_return instrs

let rec insert_heap_returns ret_ctyps = function
  | (CDEF_spec (id, _, ret_ctyp) as cdef) :: cdefs ->
     cdef :: insert_heap_returns (Bindings.add id ret_ctyp ret_ctyps) cdefs

  | CDEF_fundef (id, None, args, body) :: cdefs ->
     let gs = gensym () in
     begin match Bindings.find_opt id ret_ctyps with
     | None ->
        raise (Reporting.err_general (id_loc id) ("Cannot find return type for function " ^ string_of_id id))
     | Some ret_ctyp when not (is_stack_ctyp ret_ctyp) ->
        CDEF_fundef (id, Some gs, args, fix_early_heap_return (name gs) ret_ctyp body)
        :: insert_heap_returns ret_ctyps cdefs
     | Some ret_ctyp ->
        CDEF_fundef (id, None, args, fix_early_stack_return (name gs) ret_ctyp (idecl ret_ctyp (name gs) :: body))
        :: insert_heap_returns ret_ctyps cdefs
     end

  | CDEF_fundef (id, gs, _, _) :: _ ->
     raise (Reporting.err_unreachable (id_loc id) __POS__ "Found function with return already re-written in insert_heap_returns")

  | cdef :: cdefs ->
     cdef :: insert_heap_returns ret_ctyps cdefs

  | [] -> []

(** To keep things neat we use GCC's local labels extension to limit
   the scope of labels. We do this by iterating over all the blocks
   and adding a __label__ declaration with all the labels local to
   that block. The add_local_labels function is called by the code
   generator just before it outputs C.

   See https://gcc.gnu.org/onlinedocs/gcc/Local-Labels.html **)
let add_local_labels' instrs =
  let is_label (I_aux (instr, _)) =
    match instr with
    | I_label str -> [str]
    | _ -> []
  in
  let labels = List.concat (List.map is_label instrs) in
  let local_label_decl = iraw ("__label__ " ^ String.concat ", " labels ^ ";\n") in
  if labels = [] then
    instrs
  else
    local_label_decl :: instrs

let add_local_labels instrs =
  match map_instrs add_local_labels' (iblock instrs) with
  | I_aux (I_block instrs, _) -> instrs
  | _ -> assert false

(**************************************************************************)
(* 5. Optimizations                                                       *)
(**************************************************************************)

let hoist_ctyp = function
  | CT_lint | CT_lbits _ | CT_struct _ -> true
  | _ -> false

let hoist_counter = ref 0
let hoist_id () =
  let id = mk_id ("gh#" ^ string_of_int !hoist_counter) in
  incr hoist_counter;
  name id

let hoist_allocations recursive_functions = function
  | CDEF_fundef (function_id, _, _, _) as cdef when IdSet.mem function_id recursive_functions ->
     c_debug (lazy (Printf.sprintf "skipping recursive function %s" (string_of_id function_id)));
     [cdef]

  | CDEF_fundef (function_id, heap_return, args, body) ->
     let decls = ref [] in
     let cleanups = ref [] in
     let rec hoist = function
       | I_aux (I_decl (ctyp, decl_id), annot) :: instrs when hoist_ctyp ctyp ->
          let hid = hoist_id () in
          decls := idecl ctyp hid :: !decls;
          cleanups := iclear ctyp hid :: !cleanups;
          let instrs = instrs_rename decl_id hid instrs in
          I_aux (I_reset (ctyp, hid), annot) :: hoist instrs

       | I_aux (I_init (ctyp, decl_id, cval), annot) :: instrs when hoist_ctyp ctyp ->
          let hid = hoist_id () in
          decls := idecl ctyp hid :: !decls;
          cleanups := iclear ctyp hid :: !cleanups;
          let instrs = instrs_rename decl_id hid instrs in
          I_aux (I_reinit (ctyp, hid, cval), annot) :: hoist instrs

       | I_aux (I_clear (ctyp, _), _) :: instrs when hoist_ctyp ctyp ->
          hoist instrs

       | I_aux (I_block block, annot) :: instrs ->
          I_aux (I_block (hoist block), annot) :: hoist instrs
       | I_aux (I_try_block block, annot) :: instrs ->
          I_aux (I_try_block (hoist block), annot) :: hoist instrs
       | I_aux (I_if (cval, then_instrs, else_instrs, ctyp), annot) :: instrs ->
          I_aux (I_if (cval, hoist then_instrs, hoist else_instrs, ctyp), annot) :: hoist instrs

       | instr :: instrs -> instr :: hoist instrs
       | [] -> []
     in
     let body = hoist body in
     if !decls = [] then
       [CDEF_fundef (function_id, heap_return, args, body)]
     else
       [CDEF_startup (function_id, List.rev !decls);
        CDEF_fundef (function_id, heap_return, args, body);
        CDEF_finish (function_id, !cleanups)]

  | cdef -> [cdef]

let rec specialize_variants ctx prior =
  let unifications = ref (Bindings.empty) in

  let fix_variant_ctyp var_id new_ctors = function
    | CT_variant (id, ctors) when Id.compare id var_id = 0 -> CT_variant (id, new_ctors)
    | ctyp -> ctyp
  in

  let specialize_constructor ctx ctor_id ctyp =
    function
    | I_aux (I_funcall (clexp, extern, id, [cval]), ((_, l) as aux)) as instr when Id.compare id ctor_id = 0 ->
       (* Work out how each call to a constructor in instantiated and add that to unifications *)
       let unification = List.map ctyp_suprema (ctyp_unify ctyp (cval_ctyp cval)) in
       let mono_id = append_id ctor_id ("_" ^ Util.string_of_list "_" (fun ctyp -> Util.zencode_string (string_of_ctyp ctyp)) unification) in
       unifications := Bindings.add mono_id (ctyp_suprema (cval_ctyp cval)) !unifications;

       (* We need to cast each cval to it's ctyp_suprema in order to put it in the most general constructor *)
       let casts =
         let cast_to_suprema (frag, ctyp) =
           let suprema = ctyp_suprema ctyp in
           if ctyp_equal ctyp suprema then
             [], (unpoly frag, ctyp), []
           else
             let gs = ngensym () in
             [idecl suprema gs;
              icopy l (CL_id (gs, suprema)) (unpoly frag, ctyp)],
             (F_id gs, suprema),
             [iclear suprema gs]
         in
         List.map cast_to_suprema [cval]
       in
       let setup = List.concat (List.map (fun (setup, _, _) -> setup) casts) in
       let cvals = List.map (fun (_, cval, _) -> cval) casts in
       let cleanup = List.concat (List.map (fun (_, _, cleanup) -> cleanup) casts) in

       let mk_funcall instr =
         if List.length setup = 0 then
           instr
         else
           iblock (setup @ [instr] @ cleanup)
       in

       mk_funcall (I_aux (I_funcall (clexp, extern, mono_id, cvals), aux))

    | I_aux (I_funcall (clexp, extern, id, cvals), ((_, l) as aux)) as instr when Id.compare id ctor_id = 0 ->
       c_error ~loc:l "Multiple argument constructor found"

    | instr -> instr
  in

  function
  | (CDEF_type (CTD_variant (var_id, ctors)) as cdef) :: cdefs ->
     let polymorphic_ctors = List.filter (fun (_, ctyp) -> is_polymorphic ctyp) ctors in

     let cdefs =
       List.fold_left (fun cdefs (ctor_id, ctyp) -> List.map (cdef_map_instr (specialize_constructor ctx ctor_id ctyp)) cdefs)
                      cdefs
                      polymorphic_ctors
     in

     let monomorphic_ctors = List.filter (fun (_, ctyp) -> not (is_polymorphic ctyp)) ctors in
     let specialized_ctors = Bindings.bindings !unifications in
     let new_ctors = monomorphic_ctors @ specialized_ctors in

     let ctx = {
         ctx with variants = Bindings.add var_id
                               (List.fold_left (fun m (id, ctyp) -> Bindings.add id ctyp m) !unifications monomorphic_ctors)
                               ctx.variants
       } in

     let cdefs = List.map (cdef_map_ctyp (map_ctyp (fix_variant_ctyp var_id new_ctors))) cdefs in
     let prior = List.map (cdef_map_ctyp (map_ctyp (fix_variant_ctyp var_id new_ctors))) prior in
     specialize_variants ctx (CDEF_type (CTD_variant (var_id, new_ctors)) :: prior) cdefs

  | cdef :: cdefs ->
     let remove_poly (I_aux (instr, aux)) =
       match instr with
       | I_copy (clexp, (frag, ctyp)) when is_polymorphic ctyp ->
          I_aux (I_copy (clexp, (frag, ctyp_suprema (clexp_ctyp clexp))), aux)
       | instr -> I_aux (instr, aux)
     in
     let cdef = cdef_map_instr remove_poly cdef in
     specialize_variants ctx (cdef :: prior) cdefs

  | [] -> List.rev prior, ctx

(** Once we specialize variants, there may be additional type
   dependencies which could be in the wrong order. As such we need to
   sort the type definitions in the list of cdefs. *)
let sort_ctype_defs cdefs =
  (* Split the cdefs into type definitions and non type definitions *)
  let is_ctype_def = function CDEF_type _ -> true | _ -> false in
  let unwrap = function CDEF_type ctdef -> ctdef | _ -> assert false in
  let ctype_defs = List.map unwrap (List.filter is_ctype_def cdefs) in
  let cdefs = List.filter (fun cdef -> not (is_ctype_def cdef)) cdefs in

  let ctdef_id = function
    | CTD_enum (id, _) | CTD_struct (id, _) | CTD_variant (id, _) -> id
  in

  let ctdef_ids = function
    | CTD_enum _ -> IdSet.empty
    | CTD_struct (_, ctors) | CTD_variant (_, ctors) ->
       List.fold_left (fun ids (_, ctyp) -> IdSet.union (ctyp_ids ctyp) ids) IdSet.empty ctors
  in

  (* Create a reverse (i.e. from types to the types that are dependent
     upon them) id graph of dependencies between types *)
  let module IdGraph = Graph.Make(Id) in

  let graph =
    List.fold_left (fun g ctdef ->
        List.fold_left (fun g id -> IdGraph.add_edge id (ctdef_id ctdef) g)
          (IdGraph.add_edges (ctdef_id ctdef) [] g) (* Make sure even types with no dependencies are in graph *)
          (IdSet.elements (ctdef_ids ctdef)))
      IdGraph.empty
      ctype_defs
  in

  (* Then select the ctypes in the correct order as given by the topsort *)
  let ids = IdGraph.topsort graph in
  let ctype_defs =
    List.map (fun id -> CDEF_type (List.find (fun ctdef -> Id.compare (ctdef_id ctdef) id = 0) ctype_defs)) ids
  in

  ctype_defs @ cdefs

let removed = icomment "REMOVED"

let is_not_removed = function
  | I_aux (I_comment "REMOVED", _) -> false
  | _ -> true

(** This optimization looks for patterns of the form:

    create x : t;
    x = y;
    // modifications to x, and no changes to y
    y = x;
    // no further changes to x
    kill x;

    If found, we can remove the variable x, and directly modify y instead. *)
let remove_alias =
  let pattern ctyp id =
    let alias = ref None in
    let rec scan ctyp id n instrs =
      match n, !alias, instrs with
      | 0, None, I_aux (I_copy (CL_id (id', ctyp'), (F_id a, ctyp'')), _) :: instrs
           when Name.compare id id' = 0 && ctyp_equal ctyp ctyp' && ctyp_equal ctyp' ctyp'' ->
         alias := Some a;
         scan ctyp id 1 instrs

      | 1, Some a, I_aux (I_copy (CL_id (a', ctyp'), (F_id id', ctyp'')), _) :: instrs
           when Name.compare a a' = 0 && Name.compare id id' = 0 && ctyp_equal ctyp ctyp' && ctyp_equal ctyp' ctyp'' ->
         scan ctyp id 2 instrs

      | 1, Some a, instr :: instrs ->
         if NameSet.mem a (instr_ids instr) then
           None
         else
           scan ctyp id 1 instrs

      | 2, Some a, I_aux (I_clear (ctyp', id'), _) :: instrs
           when Name.compare id id' = 0 && ctyp_equal ctyp ctyp' ->
         scan ctyp id 2 instrs

      | 2, Some a, instr :: instrs ->
         if NameSet.mem id (instr_ids instr) then
           None
         else
           scan ctyp id 2 instrs

      | 2, Some a, [] -> !alias

      | n, _, _ :: instrs when n = 0 || n > 2 -> scan ctyp id n instrs
      | _, _, I_aux (_, (_, l)) :: instrs -> raise (Reporting.err_unreachable l __POS__ "optimize_alias")
      | _, _, [] -> None
    in
    scan ctyp id 0
  in
  let remove_alias id alias = function
    | I_aux (I_copy (CL_id (id', _), (F_id alias', _)), _)
         when Name.compare id id' = 0 && Name.compare alias alias' = 0 -> removed
    | I_aux (I_copy (CL_id (alias', _), (F_id id', _)), _)
         when Name.compare id id' = 0 && Name.compare alias alias' = 0 -> removed
    | I_aux (I_clear (_, id'), _) -> removed
    | instr -> instr
  in
  let rec opt = function
    | I_aux (I_decl (ctyp, id), _) as instr :: instrs ->
       begin match pattern ctyp id instrs with
       | None -> instr :: opt instrs
       | Some alias ->
          let instrs = List.map (map_instr (remove_alias id alias)) instrs in
          filter_instrs is_not_removed (List.map (instr_rename id alias) instrs)
       end

    | I_aux (I_block block, aux) :: instrs -> I_aux (I_block (opt block), aux) :: opt instrs
    | I_aux (I_try_block block, aux) :: instrs -> I_aux (I_try_block (opt block), aux) :: opt instrs
    | I_aux (I_if (cval, then_instrs, else_instrs, ctyp), aux) :: instrs ->
       I_aux (I_if (cval, opt then_instrs, opt else_instrs, ctyp), aux) :: opt instrs

    | instr :: instrs ->
       instr :: opt instrs
    | [] -> []
  in
  function
  | CDEF_fundef (function_id, heap_return, args, body) ->
     [CDEF_fundef (function_id, heap_return, args, opt body)]
  | cdef -> [cdef]

(** This pass ensures that all variables created by I_decl have unique names *)
let unique_names =
  let unique_counter = ref 0 in
  let unique_id () =
    let id = mk_id ("u#" ^ string_of_int !unique_counter) in
    incr unique_counter;
    name id
  in

  let rec opt seen = function
    | I_aux (I_decl (ctyp, id), aux) :: instrs when NameSet.mem id seen ->
       let id' = unique_id () in
       let instrs', seen = opt seen instrs in
       I_aux (I_decl (ctyp, id'), aux) :: instrs_rename id id' instrs', seen

    | I_aux (I_decl (ctyp, id), aux) :: instrs ->
       let instrs', seen = opt (NameSet.add id seen) instrs in
       I_aux (I_decl (ctyp, id), aux) :: instrs', seen

    | I_aux (I_block block, aux) :: instrs ->
       let block', seen = opt seen block in
       let instrs', seen = opt seen instrs in
       I_aux (I_block block', aux) :: instrs', seen

    | I_aux (I_try_block block, aux) :: instrs ->
       let block', seen = opt seen block in
       let instrs', seen = opt seen instrs in
       I_aux (I_try_block block', aux) :: instrs', seen

    | I_aux (I_if (cval, then_instrs, else_instrs, ctyp), aux) :: instrs ->
       let then_instrs', seen = opt seen then_instrs in
       let else_instrs', seen = opt seen else_instrs in
       let instrs', seen = opt seen instrs in
       I_aux (I_if (cval, then_instrs', else_instrs', ctyp), aux) :: instrs', seen

    | instr :: instrs ->
       let instrs', seen = opt seen instrs in
       instr :: instrs', seen

    | [] -> [], seen
  in
  function
  | CDEF_fundef (function_id, heap_return, args, body) ->
     [CDEF_fundef (function_id, heap_return, args, fst (opt NameSet.empty body))]
  | CDEF_reg_dec (id, ctyp, instrs) ->
     [CDEF_reg_dec (id, ctyp, fst (opt NameSet.empty instrs))]
  | CDEF_let (n, bindings, instrs) ->
     [CDEF_let (n, bindings, fst (opt NameSet.empty instrs))]
  | cdef -> [cdef]

(** This optimization looks for patterns of the form

    create x : t;
    create y : t;
    // modifications to y, no changes to x
    x = y;
    kill y;

    If found we can replace y by x *)
let combine_variables =
  let pattern ctyp id =
    let combine = ref None in
    let rec scan id n instrs =
      match n, !combine, instrs with
      | 0, None, I_aux (I_block block, _) :: instrs ->
         begin match scan id 0 block with
         | Some combine -> Some combine
         | None -> scan id 0 instrs
         end

      | 0, None, I_aux (I_decl (ctyp', id'), _) :: instrs when ctyp_equal ctyp ctyp' ->
         combine := Some id';
         scan id 1 instrs

      | 1, Some c, I_aux (I_copy (CL_id (id', ctyp'), (F_id c', ctyp'')), _) :: instrs
           when Name.compare c c' = 0 && Name.compare id id' = 0 && ctyp_equal ctyp ctyp' && ctyp_equal ctyp' ctyp'' ->
         scan id 2 instrs

      (* Ignore seemingly early clears of x, as this can happen along exception paths *)
      | 1, Some c, I_aux (I_clear (_, id'), _) :: instrs
           when Name.compare id id' = 0 ->
         scan id 1 instrs

      | 1, Some c, instr :: instrs ->
         if NameSet.mem id (instr_ids instr) then
           None
         else
           scan id 1 instrs

      | 2, Some c, I_aux (I_clear (ctyp', c'), _) :: instrs
           when Name.compare c c' = 0 && ctyp_equal ctyp ctyp' ->
         !combine

      | 2, Some c, instr :: instrs ->
         if NameSet.mem c (instr_ids instr) then
           None
         else
           scan id 2 instrs

      | 2, Some c, [] -> !combine

      | n, _, _ :: instrs -> scan id n instrs
      | _, _, [] -> None
    in
    scan id 0
  in
  let remove_variable id = function
    | I_aux (I_decl (_, id'), _) when Name.compare id id' = 0 -> removed
    | I_aux (I_clear (_, id'), _) when Name.compare id id' = 0 -> removed
    | instr -> instr
  in
  let is_not_self_assignment = function
    | I_aux (I_copy (CL_id (id, _), (F_id id', _)), _) when Name.compare id id' = 0 -> false
    | _ -> true
  in
  let rec opt = function
    | (I_aux (I_decl (ctyp, id), _) as instr) :: instrs ->
       begin match pattern ctyp id instrs with
       | None -> instr :: opt instrs
       | Some combine ->
          let instrs = List.map (map_instr (remove_variable combine)) instrs in
          let instrs = filter_instrs (fun i -> is_not_removed i && is_not_self_assignment i)
                                     (List.map (instr_rename combine id) instrs) in
          opt (instr :: instrs)
       end

    | I_aux (I_block block, aux) :: instrs -> I_aux (I_block (opt block), aux) :: opt instrs
    | I_aux (I_try_block block, aux) :: instrs -> I_aux (I_try_block (opt block), aux) :: opt instrs
    | I_aux (I_if (cval, then_instrs, else_instrs, ctyp), aux) :: instrs ->
       I_aux (I_if (cval, opt then_instrs, opt else_instrs, ctyp), aux) :: opt instrs

    | instr :: instrs ->
       instr :: opt instrs
    | [] -> []
  in
  function
  | CDEF_fundef (function_id, heap_return, args, body) ->
     [CDEF_fundef (function_id, heap_return, args, opt body)]
  | cdef -> [cdef]

(** hoist_alias looks for patterns like

    recreate x; y = x; // no furthner mentions of x

    Provided x has a certain type, then we can make y an alias to x
    (denoted in the IR as 'alias y = x'). This only works if y also has
    a lifespan that also spans the entire function body. It's possible
    we may need to do a more thorough lifetime evaluation to get this
    to be 100% correct - so it's behind the -Oexperimental flag
    for now. Some benchmarking shows that this kind of optimization
    is very valuable however! *)
let hoist_alias =
  (* Must return true for a subset of the types hoist_ctyp would return true for. *)
  let is_struct = function
    | CT_struct _ -> true
    | _ -> false
  in
  let pattern heap_return id ctyp instrs =
    let rec scan instrs =
      match instrs with
      (* The only thing that has a longer lifetime than id is the
         function return, so we want to make sure we avoid that
         case. *)
      | (I_aux (I_copy (clexp, (F_id id', ctyp')), aux) as instr) :: instrs
           when not (NameSet.mem heap_return (instr_writes instr)) && Name.compare id id' = 0
                && ctyp_equal (clexp_ctyp clexp) ctyp && ctyp_equal ctyp ctyp' ->
         if List.exists (NameSet.mem id) (List.map instr_ids instrs) then
           instr :: scan instrs
         else
           I_aux (I_alias (clexp, (F_id id', ctyp')), aux) :: instrs

      | instr :: instrs -> instr :: scan instrs
      | [] -> []
    in
    scan instrs
  in
  let optimize heap_return =
    let rec opt = function
      | (I_aux (I_reset (ctyp, id), _) as instr) :: instrs when not (is_stack_ctyp ctyp) && is_struct ctyp ->
         instr :: opt (pattern heap_return id ctyp instrs)

      | I_aux (I_block block, aux) :: instrs -> I_aux (I_block (opt block), aux) :: opt instrs
      | I_aux (I_try_block block, aux) :: instrs -> I_aux (I_try_block (opt block), aux) :: opt instrs
      | I_aux (I_if (cval, then_instrs, else_instrs, ctyp), aux) :: instrs ->
         I_aux (I_if (cval, opt then_instrs, opt else_instrs, ctyp), aux) :: opt instrs

      | instr :: instrs ->
         instr :: opt instrs
      | [] -> []
    in
    opt
  in
  function
  | CDEF_fundef (function_id, Some heap_return, args, body) ->
     [CDEF_fundef (function_id, Some heap_return, args, optimize (name heap_return) body)]
  | cdef -> [cdef]

let concatMap f xs = List.concat (List.map f xs)

let optimize recursive_functions cdefs =
  let nothing cdefs = cdefs in
  cdefs
  |> (if !optimize_alias then concatMap unique_names else nothing)
  |> (if !optimize_alias then concatMap remove_alias else nothing)
  |> (if !optimize_alias then concatMap combine_variables else nothing)
  (* We need the runtime to initialize hoisted allocations *)
  |> (if !optimize_hoist_allocations && not !opt_no_rts then concatMap (hoist_allocations recursive_functions) else nothing)
  |> (if !optimize_hoist_allocations && !optimize_experimental then concatMap hoist_alias else nothing)

(**************************************************************************)
(* 6. Code generation                                                     *)
(**************************************************************************)

let sgen_id id = Util.zencode_string (string_of_id id)
let sgen_name id = string_of_name id
let codegen_id id = string (sgen_id id)

let sgen_function_id id =
  let str = Util.zencode_string (string_of_id id) in
  !opt_prefix ^ String.sub str 1 (String.length str - 1)

let codegen_function_id id = string (sgen_function_id id)

let rec sgen_ctyp = function
  | CT_unit -> "unit"
  | CT_bit -> "fbits"
  | CT_bool -> "bool"
  | CT_fbits _ -> "fbits"
  | CT_sbits _ -> "sbits"
  | CT_fint _ -> "mach_int"
  | CT_lint -> "sail_int"
  | CT_lbits _ -> "lbits"
  | CT_tup _ as tup -> "struct " ^ Util.zencode_string ("tuple_" ^ string_of_ctyp tup)
  | CT_struct (id, _) -> "struct " ^ sgen_id id
  | CT_enum (id, _) -> "enum " ^ sgen_id id
  | CT_variant (id, _) -> "struct " ^ sgen_id id
  | CT_list _ as l -> Util.zencode_string (string_of_ctyp l)
  | CT_vector _ as v -> Util.zencode_string (string_of_ctyp v)
  | CT_string -> "sail_string"
  | CT_real -> "real"
  | CT_ref ctyp -> sgen_ctyp ctyp ^ "*"
  | CT_poly -> "POLY" (* c_error "Tried to generate code for non-monomorphic type" *)

let rec sgen_ctyp_name = function
  | CT_unit -> "unit"
  | CT_bit -> "fbits"
  | CT_bool -> "bool"
  | CT_fbits _ -> "fbits"
  | CT_sbits _ -> "sbits"
  | CT_fint _ -> "mach_int"
  | CT_lint -> "sail_int"
  | CT_lbits _ -> "lbits"
  | CT_tup _ as tup -> Util.zencode_string ("tuple_" ^ string_of_ctyp tup)
  | CT_struct (id, _) -> sgen_id id
  | CT_enum (id, _) -> sgen_id id
  | CT_variant (id, _) -> sgen_id id
  | CT_list _ as l -> Util.zencode_string (string_of_ctyp l)
  | CT_vector _ as v -> Util.zencode_string (string_of_ctyp v)
  | CT_string -> "sail_string"
  | CT_real -> "real"
  | CT_ref ctyp -> "ref_" ^ sgen_ctyp_name ctyp
  | CT_poly -> "POLY" (* c_error "Tried to generate code for non-monomorphic type" *)

let sgen_cval_param (frag, ctyp) =
  match ctyp with
  | CT_lbits direction ->
     string_of_fragment frag ^ ", " ^ string_of_bool direction
  | CT_sbits (_, direction) ->
     string_of_fragment frag ^ ", " ^ string_of_bool direction
  | CT_fbits (len, direction) ->
     string_of_fragment frag ^ ", UINT64_C(" ^ string_of_int len ^ ") , " ^ string_of_bool direction
  | _ ->
     string_of_fragment frag

let sgen_cval = function (frag, _) -> string_of_fragment frag

let rec sgen_clexp = function
  | CL_id (Have_exception _, _) -> "have_exception"
  | CL_id (Current_exception _, _) -> "current_exception"
  | CL_id (Return _, _) -> assert false
  | CL_id (Name (id, _), _) -> "&" ^ sgen_id id
  | CL_field (clexp, field) -> "&((" ^ sgen_clexp clexp ^ ")->" ^ Util.zencode_string field ^ ")"
  | CL_tuple (clexp, n) -> "&((" ^ sgen_clexp clexp ^ ")->ztup" ^ string_of_int n ^ ")"
  | CL_addr clexp -> "(*(" ^ sgen_clexp clexp ^ "))"
  | CL_void -> assert false

let rec sgen_clexp_pure = function
  | CL_id (Have_exception _, _) -> "have_exception"
  | CL_id (Current_exception _, _) -> "current_exception"
  | CL_id (Return _, _) -> assert false
  | CL_id (Name (id, _), _) -> sgen_id id
  | CL_field (clexp, field) -> sgen_clexp_pure clexp ^ "." ^ Util.zencode_string field
  | CL_tuple (clexp, n) -> sgen_clexp_pure clexp ^ ".ztup" ^ string_of_int n
  | CL_addr clexp -> "(*(" ^ sgen_clexp_pure clexp ^ "))"
  | CL_void -> assert false

(** Generate instructions to copy from a cval to a clexp. This will
   insert any needed type conversions from big integers to small
   integers (or vice versa), or from arbitrary-length bitvectors to
   and from uint64 bitvectors as needed. *)
let rec codegen_conversion l clexp cval =
  let open Printf in
  let ctyp_to = clexp_ctyp clexp in
  let ctyp_from = cval_ctyp cval in
  match ctyp_to, ctyp_from with
  (* When both types are equal, we don't need any conversion. *)
  | _, _ when ctyp_equal ctyp_to ctyp_from ->
     if is_stack_ctyp ctyp_to then
       ksprintf string "  %s = %s;" (sgen_clexp_pure clexp) (sgen_cval cval)
     else
       ksprintf string "  COPY(%s)(%s, %s);" (sgen_ctyp_name ctyp_to) (sgen_clexp clexp) (sgen_cval cval)

  | CT_ref ctyp_to, ctyp_from ->
     codegen_conversion l (CL_addr clexp) cval

  (* If we have to convert between tuple types, convert the fields individually. *)
  | CT_tup ctyps_to, CT_tup ctyps_from when List.length ctyps_to = List.length ctyps_from ->
     let conversions =
       List.mapi (fun i ctyp -> codegen_conversion l (CL_tuple (clexp, i)) (F_field (fst cval, "ztup" ^ string_of_int i), ctyp)) ctyps_from
     in
     string "  /* conversions */"
     ^^ hardline
     ^^ separate hardline conversions
     ^^ hardline
     ^^ string "  /* end conversions */"

  (* For anything not special cased, just try to call a appropriate CONVERT_OF function. *)
  | _, _ when is_stack_ctyp (clexp_ctyp clexp) ->
     ksprintf string "  %s = CONVERT_OF(%s, %s)(%s);"
              (sgen_clexp_pure clexp) (sgen_ctyp_name ctyp_to) (sgen_ctyp_name ctyp_from) (sgen_cval_param cval)
  | _, _ ->
     ksprintf string "  CONVERT_OF(%s, %s)(%s, %s);"
              (sgen_ctyp_name ctyp_to) (sgen_ctyp_name ctyp_from) (sgen_clexp clexp) (sgen_cval_param cval)

let rec codegen_instr fid ctx (I_aux (instr, (_, l))) =
  let open Printf in
  match instr with
  | I_decl (ctyp, id) when is_stack_ctyp ctyp ->
     ksprintf string "  %s %s;" (sgen_ctyp ctyp) (sgen_name id)
  | I_decl (ctyp, id) ->
     ksprintf string "  %s %s;" (sgen_ctyp ctyp) (sgen_name id) ^^ hardline
     ^^ ksprintf string "  CREATE(%s)(&%s);" (sgen_ctyp_name ctyp) (sgen_name id)

  | I_copy (clexp, cval) -> codegen_conversion l clexp cval

  | I_alias (clexp, cval) ->
     ksprintf string "  %s = %s;" (sgen_clexp_pure clexp) (sgen_cval cval)

  | I_jump (cval, label) ->
     ksprintf string "  if (%s) goto %s;" (sgen_cval cval) label

  | I_if (cval, [then_instr], [], ctyp) ->
     ksprintf string "  if (%s)" (sgen_cval cval) ^^ hardline
     ^^ twice space ^^ codegen_instr fid ctx then_instr
  | I_if (cval, then_instrs, [], ctyp) ->
     string "  if" ^^ space ^^ parens (string (sgen_cval cval)) ^^ space
     ^^ surround 0 0 lbrace (separate_map hardline (codegen_instr fid ctx) then_instrs) (twice space ^^ rbrace)
  | I_if (cval, then_instrs, else_instrs, ctyp) ->
     string "  if" ^^ space ^^ parens (string (sgen_cval cval)) ^^ space
     ^^ surround 0 0 lbrace (separate_map hardline (codegen_instr fid ctx) then_instrs) (twice space ^^ rbrace)
     ^^ space ^^ string "else" ^^ space
     ^^ surround 0 0 lbrace (separate_map hardline (codegen_instr fid ctx) else_instrs) (twice space ^^ rbrace)

  | I_block instrs ->
     string "  {"
     ^^ jump 2 2 (separate_map hardline (codegen_instr fid ctx) instrs) ^^ hardline
     ^^ string "  }"

  | I_try_block instrs ->
     string "  { /* try */"
     ^^ jump 2 2 (separate_map hardline (codegen_instr fid ctx) instrs) ^^ hardline
     ^^ string "  }"

  | I_funcall (x, extern, f, args) ->
     let c_args = Util.string_of_list ", " sgen_cval args in
     let ctyp = clexp_ctyp x in
     let is_extern = Env.is_extern f ctx.tc_env "c" || extern in
     let fname =
       if Env.is_extern f ctx.tc_env "c" then
         Env.get_extern f ctx.tc_env "c"
       else if extern then
         string_of_id f
       else
         sgen_function_id f
     in
     let fname =
       match fname, ctyp with
       | "internal_pick", _ -> Printf.sprintf "pick_%s" (sgen_ctyp_name ctyp)
       | "eq_anything", _ ->
          begin match args with
          | cval :: _ -> Printf.sprintf "eq_%s" (sgen_ctyp_name (cval_ctyp cval))
          | _ -> c_error "eq_anything function with bad arity."
          end
       | "length", _ ->
          begin match args with
          | cval :: _ -> Printf.sprintf "length_%s" (sgen_ctyp_name (cval_ctyp cval))
          | _ -> c_error "length function with bad arity."
          end
       | "vector_access", CT_bit -> "bitvector_access"
       | "vector_access", _ ->
          begin match args with
          | cval :: _ -> Printf.sprintf "vector_access_%s" (sgen_ctyp_name (cval_ctyp cval))
          | _ -> c_error "vector access function with bad arity."
          end
       | "vector_update_subrange", _ -> Printf.sprintf "vector_update_subrange_%s" (sgen_ctyp_name ctyp)
       | "vector_subrange", _ -> Printf.sprintf "vector_subrange_%s" (sgen_ctyp_name ctyp)
       | "vector_update", CT_fbits _ -> "update_fbits"
       | "vector_update", CT_lbits _ -> "update_lbits"
       | "vector_update", _ -> Printf.sprintf "vector_update_%s" (sgen_ctyp_name ctyp)
       | "string_of_bits", _ ->
          begin match cval_ctyp (List.nth args 0) with
          | CT_fbits _ -> "string_of_fbits"
          | CT_lbits _ -> "string_of_lbits"
          | _ -> assert false
          end
       | "decimal_string_of_bits", _ ->
          begin match cval_ctyp (List.nth args 0) with
          | CT_fbits _ -> "decimal_string_of_fbits"
          | CT_lbits _ -> "decimal_string_of_lbits"
          | _ -> assert false
          end
       | "internal_vector_update", _ -> Printf.sprintf "internal_vector_update_%s" (sgen_ctyp_name ctyp)
       | "internal_vector_init", _ -> Printf.sprintf "internal_vector_init_%s" (sgen_ctyp_name ctyp)
       | "undefined_vector", CT_fbits _ -> "UNDEFINED(fbits)"
       | "undefined_vector", CT_lbits _ -> "UNDEFINED(lbits)"
       | "undefined_bit", _ -> "UNDEFINED(fbits)"
       | "undefined_vector", _ -> Printf.sprintf "UNDEFINED(vector_%s)" (sgen_ctyp_name ctyp)
       | fname, _ -> fname
     in
     if fname = "sail_assert" && !optimize_experimental then
       empty
     else if fname = "reg_deref" then
       if is_stack_ctyp ctyp then
         string (Printf.sprintf  "  %s = *(%s);" (sgen_clexp_pure x) c_args)
       else
         string (Printf.sprintf  "  COPY(%s)(&%s, *(%s));" (sgen_ctyp_name ctyp) (sgen_clexp_pure x) c_args)
     else
       if is_stack_ctyp ctyp then
         string (Printf.sprintf "  %s = %s(%s%s);" (sgen_clexp_pure x) fname (extra_arguments is_extern) c_args)
       else
         string (Printf.sprintf "  %s(%s%s, %s);" fname (extra_arguments is_extern) (sgen_clexp x) c_args)

  | I_clear (ctyp, id) when is_stack_ctyp ctyp ->
     empty
  | I_clear (ctyp, id) ->
     string (Printf.sprintf "  KILL(%s)(&%s);" (sgen_ctyp_name ctyp) (sgen_name id))

  | I_init (ctyp, id, cval) ->
     codegen_instr fid ctx (idecl ctyp id) ^^ hardline
     ^^ codegen_conversion Parse_ast.Unknown (CL_id (id, ctyp)) cval

  | I_reinit (ctyp, id, cval) ->
     codegen_instr fid ctx (ireset ctyp id) ^^ hardline
     ^^ codegen_conversion Parse_ast.Unknown (CL_id (id, ctyp)) cval

  | I_reset (ctyp, id) when is_stack_ctyp ctyp ->
     string (Printf.sprintf "  %s %s;" (sgen_ctyp ctyp) (sgen_name id))
  | I_reset (ctyp, id) ->
     string (Printf.sprintf "  RECREATE(%s)(&%s);" (sgen_ctyp_name ctyp) (sgen_name id))

  | I_return cval ->
     string (Printf.sprintf "  return %s;" (sgen_cval cval))

  | I_throw cval ->
     c_error ~loc:l "I_throw reached code generator"

  | I_undefined ctyp ->
     let rec codegen_exn_return ctyp =
       match ctyp with
       | CT_unit -> "UNIT", []
       | CT_bit -> "UINT64_C(0)", []
       | CT_fint _ -> "INT64_C(0xdeadc0de)", []
       | CT_fbits _ -> "UINT64_C(0xdeadc0de)", []
       | CT_sbits _ -> "undefined_sbits()", []
       | CT_bool -> "false", []
       | CT_enum (_, ctor :: _) -> sgen_id ctor, [] 
       | CT_tup ctyps when is_stack_ctyp ctyp ->
          let gs = ngensym () in
          let fold (inits, prev) (n, ctyp) =
            let init, prev' = codegen_exn_return ctyp in
            Printf.sprintf ".ztup%d = %s" n init :: inits, prev @ prev'
          in
          let inits, prev = List.fold_left fold ([], []) (List.mapi (fun i x -> (i, x)) ctyps) in
          sgen_name gs,
          [Printf.sprintf "struct %s %s = { " (sgen_ctyp_name ctyp) (sgen_name gs)
           ^ Util.string_of_list ", " (fun x -> x) inits ^ " };"] @ prev
       | CT_struct (id, ctors) when is_stack_ctyp ctyp ->
          let gs = ngensym () in
          let fold (inits, prev) (id, ctyp) =
            let init, prev' = codegen_exn_return ctyp in
            Printf.sprintf ".%s = %s" (sgen_id id) init :: inits, prev @ prev'
          in
          let inits, prev = List.fold_left fold ([], []) ctors in
          sgen_name gs,
          [Printf.sprintf "struct %s %s = { " (sgen_ctyp_name ctyp) (sgen_name gs)
           ^ Util.string_of_list ", " (fun x -> x) inits ^ " };"] @ prev
       | ctyp -> c_error ("Cannot create undefined value for type: " ^ string_of_ctyp ctyp)
     in
     let ret, prev = codegen_exn_return ctyp in
     separate_map hardline (fun str -> string ("  " ^ str)) (List.rev prev)
     ^^ hardline
     ^^ string (Printf.sprintf "  return %s;" ret)

  | I_comment str ->
     string ("  /* " ^ str ^ " */")

  | I_label str ->
     string (str ^ ": ;")

  | I_goto str ->
     string (Printf.sprintf "  goto %s;" str)

  | I_raw _ when ctx.no_raw -> empty
  | I_raw str ->
     string ("  " ^ str)

  | I_end -> assert false

  | I_match_failure ->
     string ("  sail_match_failure(\"" ^ String.escaped (string_of_id fid) ^ "\");")

let codegen_type_def ctx = function
  | CTD_enum (id, ((first_id :: _) as ids)) ->
     let codegen_eq =
       let name = sgen_id id in
       string (Printf.sprintf "static bool eq_%s(enum %s op1, enum %s op2) { return op1 == op2; }" name name name)
     in
     let codegen_undefined =
       let name = sgen_id id in
       string (Printf.sprintf "enum %s UNDEFINED(%s)(unit u) { return %s; }" name name (sgen_id first_id))
     in
     string (Printf.sprintf "// enum %s" (string_of_id id)) ^^ hardline
     ^^ separate space [string "enum"; codegen_id id; lbrace; separate_map (comma ^^ space) codegen_id ids; rbrace ^^ semi]
     ^^ twice hardline
     ^^ codegen_eq
     ^^ twice hardline
     ^^ codegen_undefined

  | CTD_enum (id, []) -> c_error ("Cannot compile empty enum " ^ string_of_id id)

  | CTD_struct (id, ctors) ->
     let struct_ctyp = CT_struct (id, ctors) in
     c_debug (lazy (Printf.sprintf "Generating struct for %s" (full_string_of_ctyp struct_ctyp)));

     (* Generate a set_T function for every struct T *)
     let codegen_set (id, ctyp) =
       if is_stack_ctyp ctyp then
         string (Printf.sprintf "rop->%s = op.%s;" (sgen_id id) (sgen_id id))
       else
         string (Printf.sprintf "COPY(%s)(&rop->%s, op.%s);" (sgen_ctyp_name ctyp) (sgen_id id) (sgen_id id))
     in
     let codegen_setter id ctors =
       string (let n = sgen_id id in Printf.sprintf "static void COPY(%s)(struct %s *rop, const struct %s op)" n n n) ^^ space
       ^^ surround 2 0 lbrace
                   (separate_map hardline codegen_set (Bindings.bindings ctors))
                   rbrace
     in
     (* Generate an init/clear_T function for every struct T *)
     let codegen_field_init f (id, ctyp) =
       if not (is_stack_ctyp ctyp) then
         [string (Printf.sprintf "%s(%s)(&op->%s);" f (sgen_ctyp_name ctyp) (sgen_id id))]
       else []
     in
     let codegen_init f id ctors =
       string (let n = sgen_id id in Printf.sprintf "static void %s(%s)(struct %s *op)" f n n) ^^ space
       ^^ surround 2 0 lbrace
                   (separate hardline (Bindings.bindings ctors |> List.map (codegen_field_init f) |> List.concat))
                   rbrace
     in
     let codegen_eq =
       let codegen_eq_test (id, ctyp) =
         string (Printf.sprintf "EQUAL(%s)(op1.%s, op2.%s)" (sgen_ctyp_name ctyp) (sgen_id id) (sgen_id id))
       in
       string (Printf.sprintf "static bool EQUAL(%s)(struct %s op1, struct %s op2)" (sgen_id id) (sgen_id id) (sgen_id id))
       ^^ space
       ^^ surround 2 0 lbrace
            (string "return" ^^ space
             ^^ separate_map (string " && ") codegen_eq_test ctors
             ^^ string ";")
            rbrace
     in
     (* Generate the struct and add the generated functions *)
     let codegen_ctor (id, ctyp) =
       string (sgen_ctyp ctyp) ^^ space ^^ codegen_id id
     in
     string (Printf.sprintf "// struct %s" (string_of_id id)) ^^ hardline
     ^^ string "struct" ^^ space ^^ codegen_id id ^^ space
     ^^ surround 2 0 lbrace
                 (separate_map (semi ^^ hardline) codegen_ctor ctors ^^ semi)
                 rbrace
     ^^ semi ^^ twice hardline
     ^^ codegen_setter id (ctor_bindings ctors)
     ^^ (if not (is_stack_ctyp struct_ctyp) then
           twice hardline
           ^^ codegen_init "CREATE" id (ctor_bindings ctors)
           ^^ twice hardline
           ^^ codegen_init "RECREATE" id (ctor_bindings ctors)
           ^^ twice hardline
           ^^ codegen_init "KILL" id (ctor_bindings ctors)
         else empty)
     ^^ twice hardline
     ^^ codegen_eq

  | CTD_variant (id, tus) ->
     let codegen_tu (ctor_id, ctyp) =
       separate space [string "struct"; lbrace; string (sgen_ctyp ctyp); codegen_id ctor_id ^^ semi; rbrace]
     in
     (* Create an if, else if, ... block that does something for each constructor *)
     let rec each_ctor v f = function
       | [] -> string "{}"
       | [(ctor_id, ctyp)] ->
          string (Printf.sprintf "if (%skind == Kind_%s)" v (sgen_id ctor_id)) ^^ lbrace ^^ hardline
          ^^ jump 0 2 (f ctor_id ctyp)
          ^^ hardline ^^ rbrace
       | (ctor_id, ctyp) :: ctors ->
          string (Printf.sprintf "if (%skind == Kind_%s) " v (sgen_id ctor_id)) ^^ lbrace ^^ hardline
          ^^ jump 0 2 (f ctor_id ctyp)
          ^^ hardline ^^ rbrace ^^ string " else " ^^ each_ctor v f ctors
     in
     let codegen_init =
       let n = sgen_id id in
       let ctor_id, ctyp = List.hd tus in
       string (Printf.sprintf "static void CREATE(%s)(struct %s *op)" n n)
       ^^ hardline
       ^^ surround 2 0 lbrace
                   (string (Printf.sprintf "op->kind = Kind_%s;" (sgen_id ctor_id)) ^^ hardline
                    ^^ if not (is_stack_ctyp ctyp) then
                         string (Printf.sprintf "CREATE(%s)(&op->%s);" (sgen_ctyp_name ctyp) (sgen_id ctor_id))
                       else empty)
                   rbrace
     in
     let codegen_reinit =
       let n = sgen_id id in
       string (Printf.sprintf "static void RECREATE(%s)(struct %s *op) {}" n n)
     in
     let clear_field v ctor_id ctyp =
       if is_stack_ctyp ctyp then
         string (Printf.sprintf "/* do nothing */")
       else
         string (Printf.sprintf "KILL(%s)(&%s->%s);" (sgen_ctyp_name ctyp) v (sgen_id ctor_id))
     in
     let codegen_clear =
       let n = sgen_id id in
       string (Printf.sprintf "static void KILL(%s)(struct %s *op)" n n) ^^ hardline
       ^^ surround 2 0 lbrace
                   (each_ctor "op->" (clear_field "op") tus ^^ semi)
                   rbrace
     in
     let codegen_ctor (ctor_id, ctyp) =
       let ctor_args, tuple, tuple_cleanup =
         let tuple_set i ctyp =
           if is_stack_ctyp ctyp then
             string (Printf.sprintf "op.ztup%d = op%d;" i i)
           else
             string (Printf.sprintf "COPY(%s)(&op.ztup%d, op%d);" (sgen_ctyp_name ctyp) i i)
         in
         Printf.sprintf "%s op" (sgen_ctyp ctyp), empty, empty
       in
       string (Printf.sprintf "static void %s(%sstruct %s *rop, %s)" (sgen_function_id ctor_id) (extra_params ()) (sgen_id id) ctor_args) ^^ hardline
       ^^ surround 2 0 lbrace
                   (tuple
                    ^^ each_ctor "rop->" (clear_field "rop") tus ^^ hardline
                    ^^ string ("rop->kind = Kind_" ^ sgen_id ctor_id) ^^ semi ^^ hardline
                    ^^ if is_stack_ctyp ctyp then
                         string (Printf.sprintf "rop->%s = op;" (sgen_id ctor_id))
                       else
                         string (Printf.sprintf "CREATE(%s)(&rop->%s);" (sgen_ctyp_name ctyp) (sgen_id ctor_id)) ^^ hardline
                         ^^ string (Printf.sprintf "COPY(%s)(&rop->%s, op);" (sgen_ctyp_name ctyp) (sgen_id ctor_id)) ^^ hardline
                         ^^ tuple_cleanup)
                   rbrace
     in
     let codegen_setter =
       let n = sgen_id id in
       let set_field ctor_id ctyp =
         if is_stack_ctyp ctyp then
           string (Printf.sprintf "rop->%s = op.%s;" (sgen_id ctor_id) (sgen_id ctor_id))
         else
           string (Printf.sprintf "CREATE(%s)(&rop->%s);" (sgen_ctyp_name ctyp) (sgen_id ctor_id))
           ^^ string (Printf.sprintf " COPY(%s)(&rop->%s, op.%s);" (sgen_ctyp_name ctyp) (sgen_id ctor_id) (sgen_id ctor_id))
       in
       string (Printf.sprintf "static void COPY(%s)(struct %s *rop, struct %s op)" n n n) ^^ hardline
       ^^ surround 2 0 lbrace
                   (each_ctor "rop->" (clear_field "rop") tus
                    ^^ semi ^^ hardline
                    ^^ string "rop->kind = op.kind"
                    ^^ semi ^^ hardline
                    ^^ each_ctor "op." set_field tus)
                   rbrace
     in
     let codegen_eq =
       let codegen_eq_test ctor_id ctyp =
         string (Printf.sprintf "return EQUAL(%s)(op1.%s, op2.%s);" (sgen_ctyp_name ctyp) (sgen_id ctor_id) (sgen_id ctor_id))
       in
       let rec codegen_eq_tests = function
         | [] -> string "return false;"
         | (ctor_id, ctyp) :: ctors ->
            string (Printf.sprintf "if (op1.kind == Kind_%s && op2.kind == Kind_%s) " (sgen_id ctor_id) (sgen_id ctor_id)) ^^ lbrace ^^ hardline
            ^^ jump 0 2 (codegen_eq_test ctor_id ctyp)
            ^^ hardline ^^ rbrace ^^ string " else " ^^ codegen_eq_tests ctors
       in
       let n = sgen_id id in
       string (Printf.sprintf "static bool EQUAL(%s)(struct %s op1, struct %s op2) " n n n)
       ^^ surround 2 0 lbrace (codegen_eq_tests tus) rbrace
     in
     string (Printf.sprintf "// union %s" (string_of_id id)) ^^ hardline
     ^^ string "enum" ^^ space
     ^^ string ("kind_" ^ sgen_id id) ^^ space
     ^^ separate space [ lbrace;
                         separate_map (comma ^^ space) (fun id -> string ("Kind_" ^ sgen_id id)) (List.map fst tus);
                         rbrace ^^ semi ]
     ^^ twice hardline
     ^^ string "struct" ^^ space ^^ codegen_id id ^^ space
     ^^ surround 2 0 lbrace
                 (separate space [string "enum"; string ("kind_" ^ sgen_id id); string "kind" ^^ semi]
                  ^^ hardline
                  ^^ string "union" ^^ space
                  ^^ surround 2 0 lbrace
                              (separate_map (semi ^^ hardline) codegen_tu tus ^^ semi)
                              rbrace
                  ^^ semi)
                 rbrace
     ^^ semi
     ^^ twice hardline
     ^^ codegen_init
     ^^ twice hardline
     ^^ codegen_reinit
     ^^ twice hardline
     ^^ codegen_clear
     ^^ twice hardline
     ^^ codegen_setter
     ^^ twice hardline
     ^^ codegen_eq
     ^^ twice hardline
     ^^ separate_map (twice hardline) codegen_ctor tus
     (* If this is the exception type, then we setup up some global variables to deal with exceptions. *)
     ^^ if string_of_id id = "exception" then
          twice hardline
          ^^ string "struct zexception *current_exception = NULL;"
          ^^ hardline
          ^^ string "bool have_exception = false;"
        else
          empty

(** GLOBAL: because C doesn't have real anonymous tuple types
   (anonymous structs don't quite work the way we need) every tuple
   type in the spec becomes some generated named struct in C. This is
   done in such a way that every possible tuple type has a unique name
   associated with it. This global variable keeps track of these
   generated struct names, so we never generate two copies of the
   struct that is used to represent them in C.

   The way this works is that codegen_def scans each definition's type
   annotations for tuple types and generates the required structs
   using codegen_type_def before the actual definition is generated by
   codegen_def'.

   This variable should be reset to empty only when the entire AST has
   been translated to C. **)
let generated = ref IdSet.empty

let codegen_tup ctx ctyps =
  let id = mk_id ("tuple_" ^ string_of_ctyp (CT_tup ctyps)) in
  if IdSet.mem id !generated then
    empty
  else
    begin
      let _, fields = List.fold_left (fun (n, fields) ctyp -> n + 1, Bindings.add (mk_id ("tup" ^ string_of_int n)) ctyp fields)
                                     (0, Bindings.empty)
                                     ctyps
      in
      generated := IdSet.add id !generated;
      codegen_type_def ctx (CTD_struct (id, Bindings.bindings fields)) ^^ twice hardline
    end

let codegen_node id ctyp =
  string (Printf.sprintf "struct node_%s {\n  %s hd;\n  struct node_%s *tl;\n};\n" (sgen_id id) (sgen_ctyp ctyp) (sgen_id id))
  ^^ string (Printf.sprintf "typedef struct node_%s *%s;" (sgen_id id) (sgen_id id))

let codegen_list_init id =
  string (Printf.sprintf "static void CREATE(%s)(%s *rop) { *rop = NULL; }" (sgen_id id) (sgen_id id))

let codegen_list_clear id ctyp =
  string (Printf.sprintf "static void KILL(%s)(%s *rop) {\n" (sgen_id id) (sgen_id id))
  ^^ string (Printf.sprintf "  if (*rop == NULL) return;")
  ^^ (if is_stack_ctyp ctyp then empty
      else string (Printf.sprintf "  KILL(%s)(&(*rop)->hd);\n" (sgen_ctyp_name ctyp)))
  ^^ string (Printf.sprintf "  KILL(%s)(&(*rop)->tl);\n" (sgen_id id))
  ^^ string "  free(*rop);"
  ^^ string "}"

let codegen_list_set id ctyp =
  string (Printf.sprintf "static void internal_set_%s(%s *rop, const %s op) {\n" (sgen_id id) (sgen_id id) (sgen_id id))
  ^^ string "  if (op == NULL) { *rop = NULL; return; };\n"
  ^^ string (Printf.sprintf "  *rop = malloc(sizeof(struct node_%s));\n" (sgen_id id))
  ^^ (if is_stack_ctyp ctyp then
        string "  (*rop)->hd = op->hd;\n"
      else
        string (Printf.sprintf "  CREATE(%s)(&(*rop)->hd);\n" (sgen_ctyp_name ctyp))
        ^^ string (Printf.sprintf "  COPY(%s)(&(*rop)->hd, op->hd);\n" (sgen_ctyp_name ctyp)))
  ^^ string (Printf.sprintf "  internal_set_%s(&(*rop)->tl, op->tl);\n" (sgen_id id))
  ^^ string "}"
  ^^ twice hardline
  ^^ string (Printf.sprintf "static void COPY(%s)(%s *rop, const %s op) {\n" (sgen_id id) (sgen_id id) (sgen_id id))
  ^^ string (Printf.sprintf "  KILL(%s)(rop);\n" (sgen_id id))
  ^^ string (Printf.sprintf "  internal_set_%s(rop, op);\n" (sgen_id id))
  ^^ string "}"

let codegen_cons id ctyp =
  let cons_id = mk_id ("cons#" ^ string_of_ctyp ctyp) in
  string (Printf.sprintf "static void %s(%s *rop, const %s x, const %s xs) {\n" (sgen_function_id cons_id) (sgen_id id) (sgen_ctyp ctyp) (sgen_id id))
  ^^ string (Printf.sprintf "  *rop = malloc(sizeof(struct node_%s));\n" (sgen_id id))
  ^^ (if is_stack_ctyp ctyp then
        string "  (*rop)->hd = x;\n"
      else
        string (Printf.sprintf "  CREATE(%s)(&(*rop)->hd);\n" (sgen_ctyp_name ctyp))
        ^^ string (Printf.sprintf "  COPY(%s)(&(*rop)->hd, x);\n" (sgen_ctyp_name ctyp)))
  ^^ string "  (*rop)->tl = xs;\n"
  ^^ string "}"

let codegen_pick id ctyp =
  if is_stack_ctyp ctyp then
    string (Printf.sprintf "static %s pick_%s(const %s xs) { return xs->hd; }" (sgen_ctyp ctyp) (sgen_ctyp_name ctyp) (sgen_id id))
  else
    string (Printf.sprintf "static void pick_%s(%s *x, const %s xs) { COPY(%s)(x, xs->hd); }" (sgen_ctyp_name ctyp) (sgen_ctyp ctyp) (sgen_id id) (sgen_ctyp_name ctyp))

let codegen_list ctx ctyp =
  let id = mk_id (string_of_ctyp (CT_list ctyp)) in
  if IdSet.mem id !generated then
    empty
  else
    begin
      generated := IdSet.add id !generated;
      codegen_node id ctyp ^^ twice hardline
      ^^ codegen_list_init id ^^ twice hardline
      ^^ codegen_list_clear id ctyp ^^ twice hardline
      ^^ codegen_list_set id ctyp ^^ twice hardline
      ^^ codegen_cons id ctyp ^^ twice hardline
      ^^ codegen_pick id ctyp ^^ twice hardline
    end

(* Generate functions for working with non-bit vectors of some specific type. *)
let codegen_vector ctx (direction, ctyp) =
  let id = mk_id (string_of_ctyp (CT_vector (direction, ctyp))) in
  if IdSet.mem id !generated then
    empty
  else
    let vector_typedef =
      string (Printf.sprintf "struct %s {\n  size_t len;\n  %s *data;\n};\n" (sgen_id id) (sgen_ctyp ctyp))
      ^^ string (Printf.sprintf "typedef struct %s %s;" (sgen_id id) (sgen_id id))
    in
    let vector_init =
      string (Printf.sprintf "static void CREATE(%s)(%s *rop) {\n  rop->len = 0;\n  rop->data = NULL;\n}" (sgen_id id) (sgen_id id))
    in
    let vector_set =
      string (Printf.sprintf "static void COPY(%s)(%s *rop, %s op) {\n" (sgen_id id) (sgen_id id) (sgen_id id))
      ^^ string (Printf.sprintf "  KILL(%s)(rop);\n" (sgen_id id))
      ^^ string "  rop->len = op.len;\n"
      ^^ string (Printf.sprintf "  rop->data = malloc((rop->len) * sizeof(%s));\n" (sgen_ctyp ctyp))
      ^^ string "  for (int i = 0; i < op.len; i++) {\n"
      ^^ string (if is_stack_ctyp ctyp then
                   "    (rop->data)[i] = op.data[i];\n"
                 else
                   Printf.sprintf "    CREATE(%s)((rop->data) + i);\n    COPY(%s)((rop->data) + i, op.data[i]);\n" (sgen_ctyp_name ctyp) (sgen_ctyp_name ctyp))
      ^^ string "  }\n"
      ^^ string "}"
    in
    let vector_clear =
      string (Printf.sprintf "static void KILL(%s)(%s *rop) {\n" (sgen_id id) (sgen_id id))
      ^^ (if is_stack_ctyp ctyp then empty
         else
           string "  for (int i = 0; i < (rop->len); i++) {\n"
           ^^ string (Printf.sprintf "    KILL(%s)((rop->data) + i);\n" (sgen_ctyp_name ctyp))
           ^^ string "  }\n")
      ^^ string "  if (rop->data != NULL) free(rop->data);\n"
      ^^ string "}"
    in
    let vector_update =
      string (Printf.sprintf "static void vector_update_%s(%s *rop, %s op, mpz_t n, %s elem) {\n" (sgen_id id) (sgen_id id) (sgen_id id) (sgen_ctyp ctyp))
      ^^ string "  int m = mpz_get_ui(n);\n"
      ^^ string "  if (rop->data == op.data) {\n"
      ^^ string (if is_stack_ctyp ctyp then
                   "    rop->data[m] = elem;\n"
                 else
                   Printf.sprintf "  COPY(%s)((rop->data) + m, elem);\n" (sgen_ctyp_name ctyp))
      ^^ string "  } else {\n"
      ^^ string (Printf.sprintf "    COPY(%s)(rop, op);\n" (sgen_id id))
      ^^ string (if is_stack_ctyp ctyp then
                   "    rop->data[m] = elem;\n"
                 else
                   Printf.sprintf "  COPY(%s)((rop->data) + m, elem);\n" (sgen_ctyp_name ctyp))
      ^^ string "  }\n"
      ^^ string "}"
    in
    let internal_vector_update =
      string (Printf.sprintf "static void internal_vector_update_%s(%s *rop, %s op, const int64_t n, %s elem) {\n" (sgen_id id) (sgen_id id) (sgen_id id) (sgen_ctyp ctyp))
      ^^ string (if is_stack_ctyp ctyp then
                   "  rop->data[n] = elem;\n"
                 else
                   Printf.sprintf "  COPY(%s)((rop->data) + n, elem);\n" (sgen_ctyp_name ctyp))
      ^^ string "}"
    in
    let vector_access =
      if is_stack_ctyp ctyp then
        string (Printf.sprintf "static %s vector_access_%s(%s op, mpz_t n) {\n" (sgen_ctyp ctyp) (sgen_id id) (sgen_id id))
        ^^ string "  int m = mpz_get_ui(n);\n"
        ^^ string "  return op.data[m];\n"
        ^^ string "}"
      else
        string (Printf.sprintf "static void vector_access_%s(%s *rop, %s op, mpz_t n) {\n" (sgen_id id) (sgen_ctyp ctyp) (sgen_id id))
        ^^ string "  int m = mpz_get_ui(n);\n"
        ^^ string (Printf.sprintf "  COPY(%s)(rop, op.data[m]);\n" (sgen_ctyp_name ctyp))
        ^^ string "}"
    in
    let internal_vector_init =
      string (Printf.sprintf "static void internal_vector_init_%s(%s *rop, const int64_t len) {\n" (sgen_id id) (sgen_id id))
      ^^ string "  rop->len = len;\n"
      ^^ string (Printf.sprintf "  rop->data = malloc(len * sizeof(%s));\n" (sgen_ctyp ctyp))
      ^^ (if not (is_stack_ctyp ctyp) then
            string "  for (int i = 0; i < len; i++) {\n"
            ^^ string (Printf.sprintf "    CREATE(%s)((rop->data) + i);\n" (sgen_ctyp_name ctyp))
            ^^ string "  }\n"
          else empty)
      ^^ string "}"
    in
    let vector_undefined =
      string (Printf.sprintf "static void undefined_vector_%s(%s *rop, mpz_t len, %s elem) {\n" (sgen_id id) (sgen_id id) (sgen_ctyp ctyp))
      ^^ string (Printf.sprintf "  rop->len = mpz_get_ui(len);\n")
      ^^ string (Printf.sprintf "  rop->data = malloc((rop->len) * sizeof(%s));\n" (sgen_ctyp ctyp))
      ^^ string "  for (int i = 0; i < (rop->len); i++) {\n"
      ^^ string (if is_stack_ctyp ctyp then
                   "    (rop->data)[i] = elem;\n"
                 else
                   Printf.sprintf "    CREATE(%s)((rop->data) + i);\n    COPY(%s)((rop->data) + i, elem);\n" (sgen_ctyp_name ctyp) (sgen_ctyp_name ctyp))
      ^^ string "  }\n"
      ^^ string "}"
    in
    begin
      generated := IdSet.add id !generated;
      vector_typedef ^^ twice hardline
      ^^ vector_init ^^ twice hardline
      ^^ vector_clear ^^ twice hardline
      ^^ vector_undefined ^^ twice hardline
      ^^ vector_access ^^ twice hardline
      ^^ vector_set ^^ twice hardline
      ^^ vector_update ^^ twice hardline
      ^^ internal_vector_update ^^ twice hardline
      ^^ internal_vector_init ^^ twice hardline
    end

let is_decl = function
  | I_aux (I_decl _, _) -> true
  | _ -> false

let codegen_decl = function
  | I_aux (I_decl (ctyp, id), _) ->
     string (Printf.sprintf "%s %s;" (sgen_ctyp ctyp) (sgen_name id))
  | _ -> assert false

let codegen_alloc = function
  | I_aux (I_decl (ctyp, id), _) when is_stack_ctyp ctyp -> empty
  | I_aux (I_decl (ctyp, id), _) ->
     string (Printf.sprintf "  CREATE(%s)(&%s);" (sgen_ctyp_name ctyp) (sgen_name id))
  | _ -> assert false

let codegen_def' ctx = function
  | CDEF_reg_dec (id, ctyp, _) ->
     string (Printf.sprintf "// register %s" (string_of_id id)) ^^ hardline
     ^^ string (Printf.sprintf "%s %s;" (sgen_ctyp ctyp) (sgen_id id))

  | CDEF_spec (id, arg_ctyps, ret_ctyp) ->
     let static = if !opt_static then "static " else "" in
     if Env.is_extern id ctx.tc_env "c" then
       empty
     else if is_stack_ctyp ret_ctyp then
       string (Printf.sprintf "%s%s %s(%s%s);" static (sgen_ctyp ret_ctyp) (sgen_function_id id) (extra_params ()) (Util.string_of_list ", " sgen_ctyp arg_ctyps))
     else
       string (Printf.sprintf "%svoid %s(%s%s *rop, %s);" static (sgen_function_id id) (extra_params ()) (sgen_ctyp ret_ctyp) (Util.string_of_list ", " sgen_ctyp arg_ctyps))

  | CDEF_fundef (id, ret_arg, args, instrs) as def ->
     (* Extract type information about the function from the environment. *)
     let quant, Typ_aux (fn_typ, _) = Env.get_val_spec id ctx.tc_env in
     let arg_typs, ret_typ = match fn_typ with
       | Typ_fn (arg_typs, ret_typ, _) -> arg_typs, ret_typ
       | _ -> assert false
     in
     let ctx' = { ctx with local_env = add_typquant (id_loc id) quant ctx.local_env } in
     let arg_ctyps, ret_ctyp = List.map (ctyp_of_typ ctx') arg_typs, ctyp_of_typ ctx' ret_typ in

     (* Check that the function has the correct arity at this point. *)
     if List.length arg_ctyps <> List.length args then
       c_error ~loc:(id_loc id) ("function arguments "
                                 ^ Util.string_of_list ", " string_of_id args
                                 ^ " matched against type "
                                 ^ Util.string_of_list ", " string_of_ctyp arg_ctyps)
     else ();

     let instrs = add_local_labels instrs in
     let args = Util.string_of_list ", " (fun x -> x) (List.map2 (fun ctyp arg -> sgen_ctyp ctyp ^ " " ^ sgen_id arg) arg_ctyps args) in
     let function_header =
       match ret_arg with
       | None ->
          assert (is_stack_ctyp ret_ctyp);
          (if !opt_static then string "static " else empty)
          ^^ string (sgen_ctyp ret_ctyp) ^^ space ^^ codegen_function_id id ^^ parens (string (extra_params ()) ^^ string args) ^^ hardline
       | Some gs ->
          assert (not (is_stack_ctyp ret_ctyp));
          (if !opt_static then string "static " else empty)
          ^^ string "void" ^^ space ^^ codegen_function_id id
          ^^ parens (string (extra_params ()) ^^ string (sgen_ctyp ret_ctyp ^ " *" ^ sgen_id gs ^ ", ") ^^ string args)
          ^^ hardline
     in
     function_header
     ^^ string "{"
     ^^ jump 0 2 (separate_map hardline (codegen_instr id ctx) instrs) ^^ hardline
     ^^ string "}"

  | CDEF_type ctype_def ->
     codegen_type_def ctx ctype_def

  | CDEF_startup (id, instrs) ->
     let static = if !opt_static then "static " else "" in
     let startup_header = string (Printf.sprintf "%svoid startup_%s(void)" static (sgen_function_id id)) in
     separate_map hardline codegen_decl instrs
     ^^ twice hardline
     ^^ startup_header ^^ hardline
     ^^ string "{"
     ^^ jump 0 2 (separate_map hardline codegen_alloc instrs) ^^ hardline
     ^^ string "}"

  | CDEF_finish (id, instrs) ->
     let static = if !opt_static then "static " else "" in
     let finish_header = string (Printf.sprintf "%svoid finish_%s(void)" static (sgen_function_id id)) in
     separate_map hardline codegen_decl (List.filter is_decl instrs)
     ^^ twice hardline
     ^^ finish_header ^^ hardline
     ^^ string "{"
     ^^ jump 0 2 (separate_map hardline (codegen_instr id ctx) instrs) ^^ hardline
     ^^ string "}"

  | CDEF_let (number, bindings, instrs) ->
     let instrs = add_local_labels instrs in
     let setup =
       List.concat (List.map (fun (id, ctyp) -> [idecl ctyp (name id)]) bindings)
     in
     let cleanup =
       List.concat (List.map (fun (id, ctyp) -> [iclear ctyp (name id)]) bindings)
     in
     separate_map hardline (fun (id, ctyp) -> string (Printf.sprintf "%s %s;" (sgen_ctyp ctyp) (sgen_id id))) bindings
     ^^ hardline ^^ string (Printf.sprintf "static void create_letbind_%d(void) " number)
     ^^ string "{"
     ^^ jump 0 2 (separate_map hardline codegen_alloc setup) ^^ hardline
     ^^ jump 0 2 (separate_map hardline (codegen_instr (mk_id "let") { ctx with no_raw = true }) instrs) ^^ hardline
     ^^ string "}"
     ^^ hardline ^^ string (Printf.sprintf "static void kill_letbind_%d(void) " number)
     ^^ string "{"
     ^^ jump 0 2 (separate_map hardline (codegen_instr (mk_id "let") ctx) cleanup) ^^ hardline
     ^^ string "}"

(** As we generate C we need to generate specialized version of tuple,
   list, and vector type. These must be generated in the correct
   order. The ctyp_dependencies function generates a list of
   c_gen_typs in the order they must be generated. Types may be
   repeated in ctyp_dependencies so it's up to the code-generator not
   to repeat definitions pointlessly (using the !generated variable)
   *)
type c_gen_typ =
  | CTG_tup of ctyp list
  | CTG_list of ctyp
  | CTG_vector of bool * ctyp

let rec ctyp_dependencies = function
  | CT_tup ctyps -> List.concat (List.map ctyp_dependencies ctyps) @ [CTG_tup ctyps]
  | CT_list ctyp -> ctyp_dependencies ctyp @ [CTG_list ctyp]
  | CT_vector (direction, ctyp) -> ctyp_dependencies ctyp @ [CTG_vector (direction, ctyp)]
  | CT_ref ctyp -> ctyp_dependencies ctyp
  | CT_struct (_, ctors) -> List.concat (List.map (fun (_, ctyp) -> ctyp_dependencies ctyp) ctors)
  | CT_variant (_, ctors) -> List.concat (List.map (fun (_, ctyp) -> ctyp_dependencies ctyp) ctors)
  | CT_lint | CT_fint _ | CT_lbits _ | CT_fbits _ | CT_sbits _ | CT_unit | CT_bool | CT_real | CT_bit | CT_string | CT_enum _ | CT_poly -> []

let codegen_ctg ctx = function
  | CTG_vector (direction, ctyp) -> codegen_vector ctx (direction, ctyp)
  | CTG_tup ctyps -> codegen_tup ctx ctyps
  | CTG_list ctyp -> codegen_list ctx ctyp

(** When we generate code for a definition, we need to first generate
   any auxillary type definitions that are required. *)
let codegen_def ctx def =
  let ctyps = cdef_ctyps def |> CTSet.elements in
  (* We should have erased any polymorphism introduced by variants at this point! *)
  if List.exists is_polymorphic ctyps then
    let polymorphic_ctyps = List.filter is_polymorphic ctyps in
    prerr_endline (Pretty_print_sail.to_string (pp_cdef def));
    c_error (Printf.sprintf "Found polymorphic types:\n%s\nwhile generating definition."
                            (Util.string_of_list "\n" string_of_ctyp polymorphic_ctyps))
  else
    let deps = List.concat (List.map ctyp_dependencies ctyps) in
    separate_map hardline (codegen_ctg ctx) deps
    ^^ codegen_def' ctx def

let is_cdef_startup = function
  | CDEF_startup _ -> true
  | _ -> false

let sgen_startup = function
  | CDEF_startup (id, _) ->
     Printf.sprintf "  startup_%s();" (sgen_id id)
  | _ -> assert false

let sgen_instr id ctx instr =
  Pretty_print_sail.to_string (codegen_instr id ctx instr)

let is_cdef_finish = function
  | CDEF_startup _ -> true
  | _ -> false

let sgen_finish = function
  | CDEF_startup (id, _) ->
     Printf.sprintf "  finish_%s();" (sgen_id id)
  | _ -> assert false

let rec get_recursive_functions (Defs defs) =
  match defs with
  | DEF_internal_mutrec fundefs :: defs ->
     IdSet.union (List.map id_of_fundef fundefs |> IdSet.of_list) (get_recursive_functions (Defs defs))

  | (DEF_fundef fdef as def) :: defs ->
     let open Rewriter in
     let ids = ref IdSet.empty in
     let collect_funcalls e_aux annot =
       match e_aux with
       | E_app (id, args) -> (ids := IdSet.add id !ids; E_aux (e_aux, annot))
       | _ -> E_aux (e_aux, annot)
     in
     let map_exp = {
         id_exp_alg with
         e_aux = (fun (e_aux, annot) -> collect_funcalls e_aux annot)
       } in
     let map_defs = { rewriters_base with rewrite_exp = (fun _ -> fold_exp map_exp) } in
     let _ = rewrite_def map_defs def in
     if IdSet.mem (id_of_fundef fdef) !ids then
       IdSet.add (id_of_fundef fdef) (get_recursive_functions (Defs defs))
     else
       get_recursive_functions (Defs defs)

  | _ :: defs -> get_recursive_functions (Defs defs)
  | [] -> IdSet.empty

let jib_of_ast env ast =
  let ctx =
    initial_ctx
      ~convert_typ:ctyp_of_typ
      ~optimize_anf:(fun ctx aexp -> analyze_functions ctx analyze_primop (c_literals ctx aexp))
      env
  in
  Jib_compile.compile_ast ctx ast

let compile_ast env output_chan c_includes ast =
  try
    c_debug (lazy (Util.log_line __MODULE__ __LINE__ "Identifying recursive functions"));
    let recursive_functions = Spec_analysis.top_sort_defs ast |> get_recursive_functions in

    let cdefs, ctx = jib_of_ast env ast in
    let cdefs = insert_heap_returns Bindings.empty cdefs in
    let cdefs = optimize recursive_functions cdefs in

    let docs = separate_map (hardline ^^ hardline) (codegen_def ctx) cdefs in

    let preamble = separate hardline
                     ([ string "#include \"sail.h\"" ]
                      @ (if !opt_no_rts then [] else
                           [ string "#include \"rts.h\"";
                             string "#include \"elf.h\"" ])
                      @ (List.map (fun h -> string (Printf.sprintf "#include \"%s\"" h)) c_includes))
    in

    let exn_boilerplate =
      if not (Bindings.mem (mk_id "exception") ctx.variants) then ([], []) else
        ([ "  current_exception = malloc(sizeof(struct zexception));";
           "  CREATE(zexception)(current_exception);" ],
         [ "  KILL(zexception)(current_exception);";
           "  free(current_exception);";
           "  if (have_exception) fprintf(stderr, \"Exiting due to uncaught exception\\n\");" ])
    in

    let letbind_initializers =
      List.map (fun n -> Printf.sprintf "  create_letbind_%d();" n) (List.rev ctx.letbinds)
    in
    let letbind_finalizers =
      List.map (fun n -> Printf.sprintf "  kill_letbind_%d();" n) ctx.letbinds
    in
    let startup cdefs =
      List.map sgen_startup (List.filter is_cdef_startup cdefs)
    in
    let finish cdefs =
      List.map sgen_finish (List.filter is_cdef_finish cdefs)
    in

    let regs = c_ast_registers cdefs in

    let register_init_clear (id, ctyp, instrs) =
      if is_stack_ctyp ctyp then
        List.map (sgen_instr (mk_id "reg") ctx) instrs, []
      else
        [ Printf.sprintf "  CREATE(%s)(&%s);" (sgen_ctyp_name ctyp) (sgen_id id) ]
        @ List.map (sgen_instr (mk_id "reg") ctx) instrs,
        [ Printf.sprintf "  KILL(%s)(&%s);" (sgen_ctyp_name ctyp) (sgen_id id) ]
    in

    let model_init = separate hardline (List.map string
       ( [ "void model_init(void)";
           "{";
           "  setup_rts();" ]
       @ fst exn_boilerplate
       @ startup cdefs
       @ List.concat (List.map (fun r -> fst (register_init_clear r)) regs)
       @ (if regs = [] then [] else [ Printf.sprintf "  %s(UNIT);" (sgen_function_id (mk_id "initialize_registers")) ])
       @ letbind_initializers
       @ [ "}" ] ))
    in

    let model_fini = separate hardline (List.map string
       ( [ "void model_fini(void)";
           "{" ]
       @ letbind_finalizers
       @ List.concat (List.map (fun r -> snd (register_init_clear r)) regs)
       @ finish cdefs
       @ snd exn_boilerplate
       @ [ "  cleanup_rts();";
           "}" ] ))
    in

    let model_default_main = separate hardline (List.map string
         [ "int model_main(int argc, char *argv[])";
           "{";
           "  model_init();";
           "  if (process_arguments(argc, argv)) exit(EXIT_FAILURE);";
           Printf.sprintf "  %s(UNIT);" (sgen_function_id (mk_id "main"));
           "  model_fini();";
           "  return EXIT_SUCCESS;";
           "}" ] )
    in

    let model_main = separate hardline (if (!opt_no_main) then [] else List.map string
         [ "int main(int argc, char *argv[])";
           "{";
           "  return model_main(argc, argv);";
           "}" ] )
    in

    let hlhl = hardline ^^ hardline in

    Pretty_print_sail.to_string (preamble ^^ hlhl ^^ docs ^^ hlhl
                                 ^^ (if not !opt_no_rts then
                                       model_init ^^ hlhl
                                       ^^ model_fini ^^ hlhl
                                       ^^ model_default_main ^^ hlhl
                                     else
                                       empty)
                                 ^^ model_main ^^ hardline)
    |> output_string output_chan
  with
  | Type_error (_, l, err) ->
     c_error ~loc:l ("Unexpected type error when compiling to C:\n" ^ Type_error.string_of_type_error err)