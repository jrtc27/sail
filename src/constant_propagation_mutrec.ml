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
open Type_check
open Rewriter

(* Unroll mutually recursive calls, starting with the functions given as
   targets on the command line, by looking for recursive calls with (some)
   constant arguments, and creating copies of those functions with the
   constants propagated in.  This may cause branches with mutually recursively
   calls to disappear, breaking the mutually recursive cycle. *)

let targets = ref ([] : id list)

let rec is_const_exp exp = match unaux_exp exp with
  | E_lit (L_aux ((L_true | L_false | L_one | L_zero | L_num _), _)) -> true
  | E_vector es -> List.for_all is_const_exp es && is_bitvector_typ (typ_of exp)
  | E_record fes -> List.for_all is_const_fexp fes
  | _ -> false
and is_const_fexp (FE_aux (FE_Fexp (_, e), _)) = is_const_exp e

let recheck_exp exp = check_exp (env_of exp) (strip_exp exp) (typ_of exp)

(* Name function copy by encoding values of constant arguments *)
let generate_fun_id id args =
  let rec suffix exp = match unaux_exp exp with
    | E_lit (L_aux (L_one, _)) -> "1"
    | E_lit (L_aux (L_zero, _)) -> "0"
    | E_lit (L_aux (L_true, _)) -> "T"
    | E_lit (L_aux (L_false, _)) -> "F"
    | E_record fes when is_const_exp exp ->
       let fsuffix (FE_aux (FE_Fexp (id, e), _)) = suffix e
       in
       "struct" ^
       Util.zencode_string (string_of_typ (typ_of exp)) ^
       "#" ^
       String.concat "" (List.map fsuffix fes)
    | E_vector es when is_const_exp exp ->
       String.concat "" (List.map suffix es)
    | _ ->
       if is_const_exp exp
       then "#" ^ Util.zencode_string (string_of_exp exp)
       else "v"
  in
  append_id id ("#mutrec_" ^ String.concat "" (List.map suffix args))

(* Generate a val spec for a function copy, removing the constant arguments
   that will be propagated in *)
let generate_val_spec env id args l annot =
  match Env.get_val_spec_orig id env with
  | tq, Typ_aux (Typ_fn (arg_typs, ret_typ, eff), _) ->
     let orig_ksubst (kid, typ_arg) =
       match typ_arg with
       | A_aux ((A_nexp _ | A_bool _), _) -> (orig_kid kid, typ_arg)
       | _ -> raise (Reporting.err_todo l "Propagation of polymorphic arguments not implemented")
     in
     let ksubsts =
       recheck_exp (E_aux (E_app (id, args), (l, annot)))
       |> instantiation_of
       |> KBindings.bindings
       |> List.map orig_ksubst
       |> List.fold_left (fun s (v,i) -> KBindings.add v i s) KBindings.empty
     in
     let ret_typ' = KBindings.fold typ_subst ksubsts ret_typ in
     let arg_typs' =
       List.map (KBindings.fold typ_subst ksubsts) arg_typs
       |> List.map2 (fun arg typ -> if is_const_exp arg then [] else [typ]) args
       |> List.concat
       |> function [] -> [unit_typ] | typs -> typs
     in
     let typ' = mk_typ (Typ_fn (arg_typs', ret_typ', eff)) in
     let tyvars = tyvars_of_typ typ' in
     let tq' =
       quant_items tq |>
       List.filter (fun qi -> KidSet.subset (tyvars_of_quant_item qi) tyvars) |>
       mk_typquant
     in
     let typschm = mk_typschm tq' typ' in
     mk_val_spec (VS_val_spec (typschm, generate_fun_id id args, [], false)),
     ksubsts
  | _, Typ_aux (_, l) ->
     raise (Reporting.err_unreachable l __POS__ "Function val spec is not a function type")

let const_prop target defs substs ksubsts exp =
  (* Constant_propagation currently only supports nexps for kid substitutions *)
  let nexp_substs =
    KBindings.bindings ksubsts
    |> List.map (function (kid, A_aux (A_nexp n, _)) -> [(kid, n)] | _ -> [])
    |> List.concat
    |> List.fold_left (fun s (v,i) -> KBindings.add v i s) KBindings.empty
  in
  Constant_propagation.const_prop
    target
    (Defs defs)
    (Constant_propagation.referenced_vars exp)
    (substs, nexp_substs)
    Bindings.empty
    exp
  |> fst

(* Propagate constant arguments into function clause pexp *)
let prop_args_pexp target defs ksubsts args pexp =
  let pat, guard, exp, annot = destruct_pexp pexp in
  let pats = match pat with
    | P_aux (P_tup pats, _) -> pats
    | _ -> [pat]
  in
  let match_arg (E_aux (_, (l, _)) as arg) pat (pats, substs) =
    if is_const_exp arg then
      match pat with
      | P_aux (P_id id, _) -> (pats, Bindings.add id arg substs)
      | _ ->
         raise (Reporting.err_todo l
           ("Unsupported pattern match in propagation of constant arguments: " ^
            string_of_exp arg ^ " and " ^ string_of_pat pat))
    else (pat :: pats, substs)
  in
  let pats, substs = List.fold_right2 match_arg args pats ([], Bindings.empty) in
  let exp' = const_prop target defs substs ksubsts exp in
  let pat' = match pats with
    | [pat] -> pat
    | _ -> P_aux (P_tup pats, (Parse_ast.Unknown, empty_tannot))
  in
  construct_pexp (pat', guard, exp', annot)

let rewrite_defs target env (Defs defs) =
  let rec rewrite = function
    | [] -> []
    | DEF_internal_mutrec mutrecs :: ds ->
       let mutrec_ids = IdSet.of_list (List.map id_of_fundef mutrecs) in
       let valspecs = ref ([] : unit def list) in
       let fundefs = ref ([] : unit def list) in
       (* Try to replace mutually recursive calls that have some constant arguments *)
       let rec e_app (id, args) (l, annot) =
         if IdSet.mem id mutrec_ids && List.exists is_const_exp args then
           let id' = generate_fun_id id args in
           let args' = match List.filter (fun e -> not (is_const_exp e)) args with
             | [] -> [infer_exp env (mk_lit_exp L_unit)]
             | args' -> args'
           in
           if not (IdSet.mem id' (ids_of_defs (Defs !valspecs))) then begin
             (* Generate copy of function with constant arguments propagated in *)
             let (FD_aux (FD_function (_, _, _, fcls), _)) =
               List.find (fun fd -> Id.compare id (id_of_fundef fd) = 0) mutrecs
             in
             let valspec, ksubsts = generate_val_spec env id args l annot in
             let const_prop_funcl (FCL_aux (FCL_Funcl (_, pexp), (l, _))) =
               let pexp' =
                 prop_args_pexp target defs ksubsts args pexp
                 |> rewrite_pexp
                 |> strip_pexp
               in
               FCL_aux (FCL_Funcl (id', pexp'), (Parse_ast.Generated l, ()))
             in
             valspecs := valspec :: !valspecs;
             let fundef = mk_fundef (List.map const_prop_funcl fcls) in
             fundefs := fundef :: !fundefs
           end else ();
           E_aux (E_app (id', args'), (l, annot))
         else E_aux (E_app (id, args), (l, annot))
       and e_aux (e, (l, annot)) =
         match e with
         | E_app (id, args) -> e_app (id, args) (l, annot)
         | _ -> E_aux (e, (l, annot))
       and rewrite_pexp pexp = fold_pexp { id_exp_alg with e_aux = e_aux } pexp
       and rewrite_funcl (FCL_aux (FCL_Funcl (id, pexp), a) as funcl) =
         let pexp' =
           if List.exists (fun id' -> Id.compare id id' = 0) !targets then
             let pat, guard, body, annot = destruct_pexp pexp in
             let body' = const_prop target defs Bindings.empty KBindings.empty body in
             rewrite_pexp (construct_pexp (pat, guard, recheck_exp body', annot))
           else pexp
         in FCL_aux (FCL_Funcl (id, pexp'), a)
       and rewrite_fundef (FD_aux (FD_function (ropt, topt, eopt, fcls), a)) =
         let fcls' = List.map rewrite_funcl fcls in
         FD_aux (FD_function (ropt, topt, eopt, fcls'), a)
       in
       let mutrecs' = List.map (fun fd -> DEF_fundef (rewrite_fundef fd)) mutrecs in
       let (Defs fdefs) = fst (check env (Defs (!valspecs @ !fundefs))) in
       mutrecs' @ fdefs @ rewrite ds
    | d :: ds ->
       d :: rewrite ds
  in
  Spec_analysis.top_sort_defs (Defs (rewrite defs))
