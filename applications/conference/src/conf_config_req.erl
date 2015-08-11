%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2015, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%-------------------------------------------------------------------
-module(conf_config_req).

-export([handle_req/2]).

-include("conference.hrl").

-spec handle_req(wh_json:object(), wh_proplist()) -> 'ok'.
handle_req(JObj, _Options) ->
    'true' = wapi_conference:config_req_v(JObj),
    ConfigName = wh_json:get_value(<<"Profile">>, JObj),
    fetch_config(JObj, ConfigName).

-spec fetch_config(wh_json:object(), ne_binary()) -> 'ok'.
-spec fetch_config(wh_json:object(), ne_binary(), api_binary()) -> 'ok'.
fetch_config(JObj, <<"default">> = ConfigName) ->
    Config = whapps_config:get(?CONFIG_CAT
                               ,[<<"profiles">>, ConfigName]
                               ,wh_json:from_list(?DEFAULT_PROFILE_CONFIG)
                              ),
    fetch_config(JObj, ConfigName, Config);
fetch_config(JObj, ConfigName) ->
    Config = whapps_config:get(?CONFIG_CAT, [<<"profiles">>, ConfigName]),
    fetch_config(JObj, ConfigName, Config).

fetch_config(_JObj, _ConfigName, 'undefined') ->
    lager:debug("no profile defined for ~s", [_ConfigName]);
fetch_config(JObj, ConfigName, Profile) ->
    lager:debug("profile '~s' found", [ConfigName]),
    Resp = [{<<"Profiles">>, profiles(JObj, ConfigName, Profile)}
            ,{<<"Caller-Controls">>, caller_controls(ConfigName)}
            ,{<<"Advertise">>, advertise(ConfigName)}
            ,{<<"Chat-Permissions">>, chat_permissions(ConfigName)}
            ,{<<"Max-Participants">>, max_participants(JObj)}
            ,{<<"Msg-ID">>, wh_json:get_value(<<"Msg-ID">>, JObj)}
            | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    try wapi_conference:publish_config_resp(wh_json:get_value(<<"Server-ID">>, JObj)
                                            ,props:filter_undefined(Resp)
                                           )
    of
        'ok' -> 'ok'
    catch
        _E:_R ->
            ST = erlang:get_stacktrace(),
            lager:debug("failed: ~s: ~p", [_E, _R]),
            wh_util:log_stacktrace(ST)
    end.

profiles(JObj, ConfigName, Profile) ->
    Name = case get_max_participants(JObj) of
               'undefined' -> ConfigName;
               N -> << "max_participants_"
                      ,(wh_util:to_binary(N))/binary
                      ,"_"
                      ,(wh_util:rand_hex_binary(8))/binary
                    >>
           end,
    wh_json:from_list([{Name, Profile}]).

-spec get_max_participants(wh_json:object()) -> api_integer().
get_max_participants(JObj) ->
    wh_json:get_integer_value(<<"Max-Participants">>, JObj).

max_participants(JObj) ->
    case get_max_participants(JObj) of
        'undefined' -> 'undefined';
        N ->
            %% PlaySound = whapps_config:get(?%CONFIG_CAT, [<<"profiles">>, ConfigName]),
            wh_json:from_list([{<<"max-members">>, N}
                               %% ,{<<"max-members-sound">>, PlaySound}
                              ])
    end.

-spec caller_controls(ne_binary()) -> api_object().
-spec caller_controls(ne_binary(), api_object()) -> api_object().
caller_controls(<<"default">> = ConfigName) ->
    caller_controls(ConfigName, ?CALLER_CONTROLS(ConfigName, ?DEFAULT_CALLER_CONTROLS_CONFIG));
caller_controls(ConfigName) ->
    caller_controls(ConfigName, ?CALLER_CONTROLS(ConfigName)).

caller_controls(_ConfigName, 'undefined') -> 'undefined';
caller_controls(ConfigName, Controls) ->
    wh_json:from_list([{ConfigName, Controls}]).

-spec advertise(ne_binary()) -> api_object().
-spec advertise(ne_binary(), api_object()) -> api_object().
advertise(<<"default">> = ConfigName) ->
    advertise(ConfigName, ?ADVERTISE(ConfigName, ?DEFAULT_ADVERTISE_CONFIG));
advertise(ConfigName) ->
    advertise(ConfigName, ?ADVERTISE(ConfigName)).

advertise(_ConfigName, 'undefined') -> 'undefined';
advertise(ConfigName, Advertise) -> wh_json:from_list([{ConfigName, Advertise}]).

-spec chat_permissions(ne_binary()) -> api_object().
-spec chat_permissions(ne_binary(), api_object()) -> api_object().
chat_permissions(<<"default">> = ConfigName) ->
    chat_permissions(ConfigName, ?CHAT_PERMISSIONS(ConfigName, ?DEFAULT_CHAT_CONFIG));
chat_permissions(ConfigName) ->
    chat_permissions(ConfigName, ?CHAT_PERMISSIONS(ConfigName)).

chat_permissions(_ConfigName, 'undefined') -> 'undefined';
chat_permissions(ConfigName, Chat) -> wh_json:from_list([{ConfigName, Chat}]).
