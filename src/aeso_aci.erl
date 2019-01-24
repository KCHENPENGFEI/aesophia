%%%-------------------------------------------------------------------
%%% @author Robert Virding
%%% @copyright (C) 2017, Aeternity Anstalt
%%% @doc
%%%     ACI interface
%%% @end
%%% Created : 12 Dec 2017
%%%-------------------------------------------------------------------

-module(aeso_aci).

-export([encode/1,decode/1]).

%% Define records for the various typed syntactic forms. These don't
%% seem to exist elsewhere.

-record(contract, {ann,con,decls}).
-record(letfun, {ann,id,args,type,body}).
-record(type_def, {ann,id,vars,typedef}).

-record(app_t, {ann,id,fields}).
-record(tuple_t, {ann,args}).
-record(record_t, {fields}).
-record(field_t, {ann,id,type}).
-record(alias_t, {type}).
-record(variant_t, {cons}).
-record(constr_t, {ann,con,args}).

-record(arg, {ann,id,type}).
-record(id, {ann,name}).
-record(con, {ann,name}).
-record(tvar, {ann,name}).

%% encode(ContractString) -> JSON.
%%  Build a JSON structure with lists and tuples, not maps, as this
%%  allows us to order the fields in the contructed JSON string.

encode(ContractString) when is_binary(ContractString) ->
    encode(binary_to_list(ContractString));
encode(ContractString) ->
    Options = [],				%No options yet
    Ast = parse_string(ContractString),
    TypedAst = aeso_ast_infer_types:infer(Ast, Options),
    %% io:format("~p\n", [Ast]),
    %% io:format("~p\n", [TypedAst]),
    %% aeso_ast:pp(Ast),
    %% aeso_ast:pp_typed(TypedAst),
    Cname = contract_name(hd(TypedAst)),
    Tdefs = [ encode_typedef(T) || T <- sort_decls(contract_types(hd(TypedAst))) ],
    Fdefs = [ encode_func(F) || F <- sort_decls(contract_funcs(hd(TypedAst))) ],
    Jmap = [{<<"contract">>, [{<<"name">>, list_to_binary(Cname)},
			      {<<"type_defs">>, Tdefs},
			      {<<"functions">>, Fdefs}]}],
    %% io:format("~p\n", [Jmap]),
    jsx:encode(Jmap).

encode_func(Fdef) ->
    Name = function_name(Fdef),
    Args = function_args(Fdef),
    Type = function_type(Fdef),
    [{<<"name">>, list_to_binary(Name)},
     {<<"arguments">>, encode_args(Args)},
     {<<"type">>, list_to_binary(encode_type(Type))}].

encode_args(Args) ->
    [ encode_arg(A) || A <- Args ].

encode_arg(#arg{id=Id,type=T}) ->
    [{<<"name">>,list_to_binary(encode_type(Id))},
     {<<"type">>,list_to_binary(encode_type(T))}].

encode_types(Types) ->
    [ encode_type(T) || T <- Types ].

encode_type(#tvar{name=N}) -> N;
encode_type(#id{name=N}) -> N;
encode_type(#con{name=N}) -> N;
encode_type(#tuple_t{args=As}) ->
    Eas = encode_types(As),
    [$(,lists:join(",", Eas),$)];
encode_type(#record_t{fields=Fs}) ->
    Efs = encode_types(Fs),
    [${,lists:join(",", Efs),$}];
encode_type(#app_t{id=Id,fields=Fs}) ->
    Name = encode_type(Id),
    Efs = encode_types(Fs),
    [Name,"(",lists:join(",", Efs),")"];
encode_type(#field_t{id=Id,type=T}) ->
    [encode_type(Id)," : ",encode_type(T)];
encode_type(#variant_t{cons=Cs}) ->
    Ecs = encode_types(Cs),
    lists:join(" | ", Ecs);
encode_type(#constr_t{con=C,args=As}) ->
    Ec = encode_type(C),
    Eas = encode_types(As),
    [Ec,$(,lists:join(", ", Eas),$)].

encode_typedef(Type) ->
    Name = typedef_name(Type),
    Vars = typedef_vars(Type),
    Def = typedef_def(Type),
    [{<<"name">>, list_to_binary(Name)},
     {<<"vars">>, encode_tvars(Vars)},
     {<<"typedef">>, list_to_binary(encode_alias(Def))}].

encode_tvars(Vars) ->
    [ encode_tvar(V) || V <- Vars ].

encode_tvar(#tvar{name=N}) ->
    [{<<"name">>, list_to_binary(N)}].

encode_alias(#alias_t{type=T}) ->
    encode_type(T);
encode_alias(A) -> encode_type(A).

%% decode(JSON) -> ContractString.
%%  Decode a JSON string and generate a suitable contract string which
%%  can be included in a contract definition. We decode into a map
%%  here as this is easier to work with and order is not important.

decode(Json) ->
    Map = jsx:decode(Json, [return_maps]),
    %% io:format("~p\n", [Map]),
    #{<<"contract">> := C} = Map,
    lists:flatten(decode_contract(C)).

decode_contract(#{<<"name">> := Name,
		  <<"type_defs">> := _Ts,
		  <<"functions">> := Fs}) ->
    ["contract"," ",io_lib:format("~s", [Name])," =\n",
     [],					%Don't include types yet.
     %% decode_tdefs(Ts),
     decode_funcs(Fs)].

decode_funcs(Fs) -> [ decode_func(F) || F <- Fs].

decode_func(#{<<"name">> := Name,<<"arguments">> := As,<<"type">> := T}) ->
    ["  function"," ",io_lib:format("~s", [Name])," : ",
     decode_args(As)," => ",decode_type(T),$\n].

decode_type(T) -> io_lib:format("~s", [T]).

decode_args(As) ->
    Das = [ decode_arg(A) || A <- As ],
    [$(,lists:join(", ", Das),$)].

decode_arg(#{<<"type">> := T}) -> decode_type(T).

decode_tdefs(Ts) -> [ decode_tdef(T) || T <- Ts ].

decode_tdef(#{<<"name">> := Name,<<"vars">> := Vs,<<"typedef">> := T}) ->
    ["  type"," ",io_lib:format("~s", [Name]),decode_tvars(Vs),
     " = ",decode_type(T),$\n].

decode_tvars([]) -> [];				%No tvars, no parentheses
decode_tvars(Vs) ->
    Dvs = [ decode_tvar(V) || V <- Vs ],
    [$(,lists:join(", ", Dvs),$)].

decode_tvar(#{<<"name">> := N}) -> io_lib:format("~s", [N]).

%% #contract{Ann, Con, [Declarations]}.

contract_name(#contract{con=#con{name=N}}) -> N.

contract_funcs(#contract{decls=Decls}) ->
    [ D || D <- Decls, is_record(D, letfun) ].

contract_types(#contract{decls=Decls}) ->
    [ D || D <- Decls, is_record(D, type_def) ].

sort_decls(Ds) ->
    %% We can easily sort them in annotation, they all should have the
    %% same column.
    Sort = fun (D1, D2) ->
		   aeso_syntax:get_ann(D1) =< aeso_syntax:get_ann(D2)
	   end,
    lists:sort(Sort, Ds).

%% #letfun{Ann, Id, [Arg], Type, Typedef}.

function_name(#letfun{id=#id{name=N}}) -> N.

function_args(#letfun{args=Args}) -> Args.

function_type(#letfun{type=Type}) -> Type.

%% #type_def{Ann, Id, [Var], Typedef}.

typedef_name(#type_def{id=#id{name=N}}) -> N.

typedef_vars(#type_def{vars=Vars}) -> Vars.

typedef_def(#type_def{typedef=Def}) -> Def.

parse_string(Text) ->
    %% Try and return something sensible here!
    case aeso_parser:string(Text) of
        %% Yay, it worked!
        {ok, Contract} -> Contract;
        %% Scan errors.
        {error, {Pos, scan_error}} ->
            parse_error(Pos, "scan error");
        {error, {Pos, scan_error_no_state}} ->
            parse_error(Pos, "scan error");
        %% Parse errors.
        {error, {Pos, parse_error, Error}} ->
            parse_error(Pos, Error);
        {error, {Pos, ambiguous_parse, As}} ->
            ErrorString = io_lib:format("Ambiguous ~p", [As]),
            parse_error(Pos, ErrorString)
    end.

parse_error({Line,Pos}, ErrorString) ->
    Error = io_lib:format("line ~p, column ~p: ~s", [Line,Pos,ErrorString]),
    error({parse_errors,[Error]}).
