%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2015, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Peter Defebvre
%%%-------------------------------------------------------------------
-module(crossbar_services).

-export([maybe_dry_run/2, maybe_dry_run/3]).

-include("crossbar.hrl").

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-type callback() :: fun(() -> cb_context:context()).

-spec maybe_dry_run(cb_context:context(), callback()) -> cb_context:context().
-spec maybe_dry_run(cb_context:context(), callback(), ne_binary() | wh_proplist()) ->
                           cb_context:context().
maybe_dry_run(Context, Callback) ->
    Type = wh_doc:type(cb_context:doc(Context)),
    maybe_dry_run(Context, Callback, Type).

maybe_dry_run(Context, Callback, Type) when is_binary(Type) ->
    maybe_dry_run_by_type(Context, Callback, Type, cb_context:accepting_charges(Context));
maybe_dry_run(Context, Callback, Props) ->
    maybe_dry_run_by_props(Context, Callback, Props, cb_context:accepting_charges(Context)).

-spec maybe_dry_run_by_props(cb_context:context(), callback(), wh_proplist(), boolean()) ->
                                    cb_context:context().
maybe_dry_run_by_props(Context, Callback, Props, 'true') ->
    Type = props:get_ne_binary_value(<<"type">>, Props),
    lager:debug("calc services updates of ~s for ~s"
                ,[Type, cb_context:account_id(Context)]
               ),
    UpdatedServices = calc_service_updates(Context, Type, props:delete(<<"type">>, Props)),
    RespJObj = dry_run(UpdatedServices),
    lager:debug("accepting charges: ~s", [wh_json:encode(RespJObj)]),
    _ = accepting_charges(Context, RespJObj, UpdatedServices),
    Callback();
maybe_dry_run_by_props(Context, Callback, Props, 'false') ->
    Type = props:get_ne_binary_value(<<"type">>, Props),
    lager:debug("calc services updates of ~s for ~s", [Type, cb_context:account_id(Context)]),
    UpdatedServices = calc_service_updates(Context, Type, props:delete(<<"type">>, Props)),
    RespJObj = dry_run(UpdatedServices),
    lager:debug("not accepting charges: ~s", [wh_json:encode(RespJObj)]),

    handle_dry_run_resp(Context, Callback, UpdatedServices, RespJObj).

-spec handle_dry_run_resp(cb_context:context(), callback(), wh_services:services(), wh_json:object()) ->
                                 cb_context:context().
handle_dry_run_resp(Context, Callback, Services, RespJObj) ->
    case wh_json:is_empty(RespJObj) of
        'true' ->
            lager:debug("no dry_run charges to accept; this service update is not a drill people!"),
            save_an_audit_log(Context, Services),
            Callback();
        'false' ->
            lager:debug("this update requires service changes to be accepted, do not be alarmed"),
            crossbar_util:response_402(RespJObj, Context)
    end.

-spec maybe_dry_run_by_type(cb_context:context(), callback(), ne_binary(), boolean()) ->
                                   cb_context:context().
maybe_dry_run_by_type(Context, Callback, Type, 'true') ->
    lager:debug("calc services updates of ~s for ~s", [Type, cb_context:account_id(Context)]),
    UpdatedServices = calc_service_updates(Context, Type),
    RespJObj = dry_run(UpdatedServices),
    lager:debug("accepting charges: ~s", [wh_json:encode(RespJObj)]),
    _ = accepting_charges(Context, RespJObj, UpdatedServices),
    Callback();
maybe_dry_run_by_type(Context, Callback, Type, 'false') ->
    lager:debug("calc services updates of ~s for ~s", [Type, cb_context:account_id(Context)]),
    UpdatedServices = calc_service_updates(Context, Type),
    RespJObj = dry_run(UpdatedServices),

    handle_dry_run_resp(Context, Callback, UpdatedServices, RespJObj).

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec accepting_charges(cb_context:context(), wh_json:object(), wh_services:services()) -> 'ok' | 'error'.
accepting_charges(Context, JObj, Services) ->
    Items = extract_items(wh_json:delete_key(<<"activation_charges">>, JObj)),
    Transactions =
        lists:foldl(
          fun(Item, Acc) ->
                  create_transactions(Context, Item, Acc)
          end
          ,[]
          ,Items
         ),
    case wh_services:commit_transactions(Services, Transactions) of
        'ok' -> save_an_audit_log(Context, Services);
        'error' -> 'error'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec extract_items(wh_json:object()) -> wh_json:objects().
extract_items(JObj) ->
    wh_json:foldl(fun extract_items_from_category/3
                  ,[]
                  ,JObj
                 ).

-spec extract_items_from_category(wh_json:key(), wh_json:object(), wh_json:objects()) ->
                                         wh_json:objects().
extract_items_from_category(_, CategoryJObj, Acc) ->
    wh_json:foldl(fun extract_item_from_category/3
                  ,Acc
                  ,CategoryJObj
                 ).

-spec extract_item_from_category(wh_json:key(), wh_json:object(), wh_json:objects()) ->
                                         wh_json:objects().
extract_item_from_category(_, ItemJObj, Acc) ->
    [ItemJObj|Acc].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create_transactions(cb_context:context()
                          ,wh_json:object()
                          ,wh_transaction:transactions()) -> wh_transaction:transactions().
-spec create_transactions(cb_context:context()
                          ,wh_json:object()
                          ,wh_transaction:transactions()
                          ,integer()) -> wh_transaction:transactions().
create_transactions(Context, Item, Acc) ->
    Quantity = wh_json:get_integer_value(<<"quantity">>, Item, 0),
    create_transactions(Context, Item, Acc, Quantity).

create_transactions(_Context, _Item, Acc, 0) -> Acc;
create_transactions(Context, Item, Acc, Quantity) ->
    AccountId = cb_context:account_id(Context),
    Amount = wh_json:get_integer_value(<<"activation_charges">>, Item, 0),
    Units = wht_util:dollars_to_units(Amount),
    Routines = [fun set_meta_data/3
                ,fun set_event/3
               ],
    Transaction =
        lists:foldl(
          fun(F, T) -> F(Context, Item, T) end
          ,wh_transaction:debit(AccountId, Units)
          ,Routines
         ),
    create_transactions(Context, Item, [Transaction|Acc], Quantity-1).

-spec set_meta_data(cb_context:context()
                    ,wh_json:object()
                    ,wh_transaction:transaction()
                   ) -> wh_transaction:transaction().
set_meta_data(Context, Item, Transaction) ->
    MetaData =
        wh_json:from_list(
          [{<<"auth_account_id">>, cb_context:auth_account_id(Context)}
           ,{<<"category">>, wh_json:get_value(<<"category">>, Item)}
           ,{<<"item">>, wh_json:get_value(<<"item">>, Item)}
          ]),
    wh_transaction:set_metadata(MetaData, Transaction).

-spec set_event(cb_context:context() ,wh_json:object()
                ,wh_transaction:transaction()) -> wh_transaction:transaction().
set_event(_Context, Item, Transaction) ->
    ItemValue = wh_json:get_value(<<"item">>, Item, <<>>),
    Event = <<"Activation charges for ", ItemValue/binary>>,
    wh_transaction:set_event(Event, Transaction).

-spec dry_run(wh_services:services() | 'undefined') -> wh_json:object().
dry_run('undefined') -> wh_json:new();
dry_run(Services) ->
    lager:debug("updated services, checking for dry run"),
    wh_services:dry_run(Services).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec calc_service_updates(cb_context:context(), ne_binary()) ->
                                  wh_services:services() | 'undefined'.
-spec calc_service_updates(cb_context:context(), ne_binary(), wh_proplist()) ->
                                  wh_services:services() | 'undefined'.
calc_service_updates(Context, <<"device">>) ->
    DeviceType = kz_device:device_type(cb_context:doc(Context)),
    calc_device_service_updates(fetch_services(Context), DeviceType);
calc_service_updates(Context, <<"user">>) ->
    JObj = cb_context:doc(Context),
    UserType = wh_json:get_value(<<"priv_level">>, JObj),
    calc_user_service_updates(fetch_services(Context), UserType);
calc_service_updates(Context, <<"limits">>) ->
    Updates = limits_updates(Context),
    calc_limits_service_updates(fetch_services(Context), Updates);
calc_service_updates(Context, <<"port_request">>) ->
    PhoneNumbers = port_request_phone_numbers(Context),
    calc_port_request_service_updates(fetch_services(Context), PhoneNumbers);
calc_service_updates(Context, <<"app">>) ->
    [{<<"apps_store">>, [Id]} | _] = cb_context:req_nouns(Context),
    case wh_service_ui_apps:is_in_use(cb_context:req_data(Context)) of
        'false' -> 'undefined';
        'true' ->
            AppName = wh_json:get_value(<<"name">>, cb_context:fetch(Context, Id)),
            calc_app_service_updates(fetch_services(Context), AppName)
    end;
calc_service_updates(Context, <<"ips">>) ->
    calc_ips_service_updates(fetch_services(Context));
calc_service_updates(Context, <<"branding">>) ->
    calc_branding_service_updates(fetch_services(Context));
calc_service_updates(_Context, _Type) ->
    lager:warning("unknown type ~p, cannot calculate service updates", [_Type]),
    'undefined'.

calc_service_updates(Context, <<"ips">>, Props) ->
    calc_ips_service_updates(fetch_services(Context), Props);
calc_service_updates(_Context, _Type, _Props) ->
    lager:warning("unknown type ~p, cannot execute dry run", [_Type]),
    'undefined'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-type reconcile_fun() :: 'reconcile' | 'reconcile_cascade'.
-spec fetch_services(cb_context:context()) ->
                            {wh_services:services(), reconcile_fun()}.
fetch_services(Context) ->
    AccountId = cb_context:account_id(Context),
    AuthAccountId = cb_context:auth_account_id(Context),
    case wh_services:is_reseller(AuthAccountId) of
        'false' ->
            lager:debug("auth account ~s is not a reseller, loading service account ~s"
                        ,[AuthAccountId, AccountId]
                       ),
            {wh_services:fetch(AccountId), 'reconcile'};
        'true' ->
            lager:debug("auth account ~s is a reseller, loading service from reseller", [AuthAccountId]),
            {wh_services:fetch(AuthAccountId), 'reconcile_cascade'}
    end.

-spec base_audit_log(cb_context:context(), wh_services:services()) ->
                            wh_json:object().
base_audit_log(Context, Services) ->
    AccountJObj = cb_context:account_doc(Context),
    Tree = kz_account:tree(AccountJObj) ++ [cb_context:account_id(Context)],

    lists:foldl(fun base_audit_log_fold/2
                ,kzd_audit_log:new()
                ,[{fun kzd_audit_log:set_tree/2, Tree}
                  ,{fun kzd_audit_log:set_authenticating_user/2, base_auth_user(Context)}
                  ,{fun kzd_audit_log:set_audit_account/3
                    ,cb_context:account_id(Context)
                    ,base_audit_account(Context, Services)
                   }
                 ]
               ).

-type audit_log_fun_2() :: {fun((kzd_audit_log:doc(), Term) -> kzd_audit_log:doc()), Term}.
-type audit_log_fun_3() :: {fun((kzd_audit_log:doc(), Term1, Term2) -> kzd_audit_log:doc()), Term1, Term2}.
-type audit_log_fun() ::  audit_log_fun_2() | audit_log_fun_3().

-spec base_audit_log_fold(audit_log_fun(), kzd_audit_log:doc()) -> kzd_audit_log:doc().
base_audit_log_fold({F, V}, Acc) -> F(Acc, V);
base_audit_log_fold({F, V1, V2}, Acc) -> F(Acc, V1, V2).

-spec base_audit_account(cb_context:context(), wh_services:services()) ->
                                wh_json:object().
base_audit_account(Context, Services) ->
    AccountName = kz_account:name(cb_context:account_doc(Context)),
    Diff = wh_services:diff_quantities(Services),

    wh_json:from_list(
      props:filter_empty(
        [{<<"account_name">>, AccountName}
         ,{<<"diff_quantities">>, Diff}
        ]
       )).

-spec base_auth_user(cb_context:context()) -> wh_json:object().
base_auth_user(Context) ->
    AuthJObj = cb_context:auth_doc(Context),
    AccountJObj = cb_context:auth_account_doc(Context),

    AccountName = kz_account:name(AccountJObj),
    wh_json:set_value(<<"account_name">>
                      ,AccountName
                      ,leak_auth_pvt_fields(AuthJObj)
                     ).

-spec leak_auth_pvt_fields(wh_json:object()) -> wh_json:object().
leak_auth_pvt_fields(JObj) ->
    wh_json:set_values([{<<"account_id">>, wh_doc:account_id(JObj)}
                        ,{<<"created">>, wh_doc:created(JObj)}
                       ]
                       ,wh_json:public_fields(JObj)
                      ).

-spec save_an_audit_log(cb_context:context(), wh_services:services() | 'undefined') -> 'ok'.
save_an_audit_log(_Context, 'undefined') -> 'ok';
save_an_audit_log(Context, Services) ->
    BaseAuditLog = base_audit_log(Context, Services),
    case cb_context:account_id(Context) =:= wh_services:account_id(Services) of
        'true' ->
            lager:debug("not forcing audit log to be saved to ~s", [wh_services:account_id(Services)]);
        'false' ->
            _Res = (catch save_subaccount_audit_log(Context, BaseAuditLog)),
            lager:debug("saving audit log to ~s: ~p", [cb_context:account_id(Context), _Res])
    end,
    kzd_audit_log:save(Services, BaseAuditLog).

-spec save_subaccount_audit_log(cb_context:context(), kzd_audit_log:doc()) -> 'ok'.
save_subaccount_audit_log(Context, BaseAuditLog) ->
    MODb = cb_context:account_modb(Context),
    {'ok', _Saved} = kazoo_modb:save_doc(MODb, BaseAuditLog),
    lager:debug("saved sub account ~s's audit log", [cb_context:account_id(Context)]).

-spec calc_device_service_updates({wh_services:services(), reconcile_fun()}, ne_binary()) ->
                                         wh_services:services().
calc_device_service_updates({Services, 'reconcile'}, DeviceType) ->
    wh_service_devices:reconcile(Services, DeviceType);
calc_device_service_updates({Services, 'reconcile_cascade'}, DeviceType) ->
    wh_service_devices:reconcile_cascade(Services, DeviceType).

-spec calc_user_service_updates({wh_services:services(), reconcile_fun()}, ne_binary()) ->
                                         wh_services:services().
calc_user_service_updates({Services, 'reconcile'}, UserType) ->
    wh_service_users:reconcile(Services, UserType);
calc_user_service_updates({Services, 'reconcile_cascade'}, UserType) ->
    wh_service_users:reconcile_cascade(Services, UserType).

-spec calc_limits_service_updates({wh_services:services(), reconcile_fun()}, wh_json:object()) ->
                                         wh_services:services().
calc_limits_service_updates({Services, 'reconcile'}, Updates) ->
    wh_service_limits:reconcile(Services, Updates);
calc_limits_service_updates({Services, 'reconcile_cascade'}, Updates) ->
    wh_service_limits:reconcile_cascade(Services, Updates).

-spec limits_updates(cb_context:context()) -> wh_json:object().
limits_updates(Context) ->
    ReqData = cb_context:req_data(Context),

    ItemTwoWay = wh_service_limits:item_twoway(),
    ItemOutbound = wh_service_limits:item_outbound(),
    ItemInbound = wh_service_limits:item_inbound(),

    wh_json:from_list(
      props:filter_undefined(
        [{ItemTwoWay, wh_json:get_integer_value(ItemTwoWay, ReqData)}
         ,{ItemInbound, wh_json:get_integer_value(ItemInbound, ReqData)}
         ,{ItemOutbound, wh_json:get_integer_value(ItemOutbound, ReqData)}
        ])
     ).

-spec calc_port_request_service_updates({wh_services:services(), reconcile_fun()}, wh_json:object()) ->
                                               wh_services:services().
calc_port_request_service_updates({Services, 'reconcile'}, PhoneNumbers) ->
    wh_service_phone_numbers:reconcile(PhoneNumbers, Services);
calc_port_request_service_updates({Services, 'reconcile_cascade'}, PhoneNumbers) ->
    wh_service_phone_numbers:reconcile_cascade(PhoneNumbers, Services).

-spec port_request_phone_numbers(cb_context:context()) -> wh_json:object().
port_request_phone_numbers(Context) ->
    JObj = cb_context:doc(Context),
    Numbers = wh_json:get_value(<<"numbers">>, JObj),
    wh_json:foldl(
      fun port_request_foldl/3
      ,wh_json:new()
      ,Numbers
     ).

-spec port_request_foldl(ne_binary(), wh_json:object(), wh_json:object()) ->
                                wh_json:object().
port_request_foldl(Number, NumberJObj, JObj) ->
    wh_json:set_value(
      Number
      ,wh_json:set_value(
         <<"features">>
         ,[<<"port">>]
         ,NumberJObj
        )
      ,JObj
     ).

-spec calc_app_service_updates({wh_services:services(), reconcile_fun()}, ne_binary()) ->
                                      wh_services:services().
calc_app_service_updates({Services, 'reconcile'}, AppName) ->
    wh_service_ui_apps:reconcile(Services, AppName);
calc_app_service_updates({Services, 'reconcile_cascade'}, AppName) ->
    wh_service_ui_apps:reconcile_cascade(Services, AppName).

-spec calc_ips_service_updates({wh_services:services(), reconcile_fun()}) ->
                                      wh_services:services().
-spec calc_ips_service_updates({wh_services:services(), reconcile_fun()}, wh_proplist()) ->
                                      wh_services:services().
calc_ips_service_updates({Services, 'reconcile'}) ->
    wh_service_ips:reconcile(Services, <<"dedicated">>);
calc_ips_service_updates({Services, 'reconcile_cascade'}) ->
    wh_service_ips:reconcile_cascade(Services, <<"dedicated">>).

calc_ips_service_updates({Services, 'reconcile'}, Props) ->
    wh_service_ips:reconcile(Services, Props);
calc_ips_service_updates({Services, 'reconcile_cascade'}, Props) ->
    wh_service_ips:reconcile_cascade(Services, Props).

-spec calc_branding_service_updates({wh_services:services(), reconcile_fun()}) ->
                                      wh_services:services().
calc_branding_service_updates({Services, 'reconcile'}) ->
    wh_service_whitelabel:reconcile(Services, <<"whitelabel">>);
calc_branding_service_updates({Services, 'reconcile_cascade'}) ->
    wh_service_whitelabel:reconcile_cascade(Services, <<"whitelabel">>).
