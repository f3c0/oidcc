-module(oidcc_openid_provider).
-behaviour(gen_server).

%% API.
-export([start_link/2]).
-export([stop/1]).
-export([is_issuer/2]).
-export([is_ready/1]).
-export([get_config/1]).
-export([update_config/1]).
-export([get_error/1]).


%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
          ready = false,
          error = undefined,

          id = undefined,
          name = undefined,
          desc = undefined,
          client_id = undefined,
          client_secret = undefined,
          request_scopes = undefined,
          issuer = undefined,
          config_ep = undefined,
          config = #{},
          keys = [],
          lasttime_updated = undefined,
          local_endpoint = undefined,
          meta_data = #{},

          gun_pid = undefined,
          config_tries = 0,
          mref = undefined,
          sref = undefined,
          method = get,
          header = [],
          body = <<>>,
          path = undefined,
          http = #{},
          retrieving = undefined
         }).

%% API.

-spec start_link(Id :: binary(), Config::map()) -> {ok, pid()}.
start_link(Id, Config) ->
    gen_server:start_link(?MODULE, {Id, Config}, []).

-spec stop(Pid ::pid()) -> ok.
stop(Pid) ->
    gen_server:cast(Pid, stop).

-spec update_config(Pid :: pid() ) -> ok.
update_config(Pid) ->
    gen_server:call(Pid, update_config).

-spec is_issuer(Issuer :: binary(), Pid :: pid() ) -> true | false.
is_issuer(Issuer, Pid) ->
    gen_server:call(Pid, {is_issuer, Issuer}).

-spec is_ready(Pid :: pid() ) -> true | false.
is_ready(Pid) ->
    gen_server:call(Pid, is_ready).

-spec get_config( Pid :: pid() ) -> {ok, Config :: map()}.
get_config( Pid) ->
    gen_server:call(Pid, get_config).

-spec get_error( Pid :: pid() ) -> {ok, term()}.
get_error( Pid) ->
    gen_server:call(Pid, get_error).

%% gen_server.
-define(MAX_TRIES, 5).

init({Id, Config}) ->

    #{name := Name,
      description := Description,
      request_scopes := Scopes,
      issuer_or_endpoint := IssuerOrEndpoint,
      local_endpoint := LocalEndpoint
     } = Config,
    ClientSecret = maps:get(client_secret, Config, undefined),
    ClientId = case ClientSecret of
                   undefined ->
                       undefined;
                   _ ->
                       maps:get(client_id, Config, undefined)
               end,
    trigger_config_retrieval(),
    ConfigEndpoint = to_config_endpoint(IssuerOrEndpoint),
    Issuer = config_ep_to_issuer(ConfigEndpoint),
    {ok, #state{id = Id, name = Name, desc = Description, client_id = ClientId,
                client_secret = ClientSecret, config_ep = ConfigEndpoint,
                request_scopes = Scopes, local_endpoint = LocalEndpoint,
                issuer = Issuer
               }}.

handle_call(get_config, _From, State) ->
    Conf = create_config(State),
    {reply, {ok, Conf}, State};
handle_call(get_error, _From, #state{error=Error} = State) ->
    {reply, {ok, Error}, State};
handle_call(update_config, _From, State) ->
    ok = trigger_config_retrieval(),
    {reply, ok, State#state{config_tries=0}};
handle_call({is_issuer, Issuer}, _From, #state{config=Config}=State) ->
    Result = (Issuer == maps:get(issuer, Config, undefined)),
    {reply, Result , State};
handle_call(is_ready, _From, #state{ready=Ready}=State) ->
    {reply, Ready, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.


handle_cast(retrieve_config, #state{gun_pid = undefined} = State) ->
    {ok, ConPid, MRef, Path} = retrieve_config(State),
    NewState = State#state{gun_pid = ConPid,
                           mref=MRef,
                           sref=undefined,
                           path=Path,
                           method = get,
                           header = [],
                           body = <<>>,
                           retrieving=config},
    {noreply, NewState};
handle_cast(retrieve_keys, State) ->
    {ok, ConPid, MRef, Path, Error} = retrieve_keys(State),
    Header = [{<<"accept">>, "application/json;q=0.7,application/jwk+json"}],
    NewState = State#state{gun_pid = ConPid,
                           mref=MRef,
                           sref=undefined,
                           path=Path,
                           method = get,
                           body = <<>>,
                           header = Header,
                           error = Error,
                           retrieving=keys},
    {noreply, NewState};
handle_cast(register_if_needed, #state{client_id = undefined,
                                       local_endpoint=LocalEndpoint} = State) ->
    {ok, ConPid, MRef, Path, Error} = register_client(State),
    Header = [{<<"content-type">>, "application/json"}],
    Body = jsone:encode(#{application_type => <<"web">>,
                          redirect_uris => [LocalEndpoint]
                          %TODO: add more and make this configurable
                         }),
    NewState = State#state{gun_pid = ConPid,
                           mref=MRef,
                           sref=undefined,
                           path=Path,
                           method = post,
                           body = Body,
                           header = Header,
                           error = Error,
                           retrieving=registration},
    {noreply, NewState};
handle_cast(register_if_needed, State) ->
    {noreply, State#state{ready=true} };
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.



handle_info({gun_up, ConPid, _Protocol},
            #state{path=Path, header=Header, gun_pid=ConPid, method=Method
                  , body=Body} = State) ->
    {ok, StreamRef} = oidcc_http_util:async_http(Method, Path, Header,
                                                 Body, ConPid),
    {noreply, State#state{sref=StreamRef}};
handle_info({gun_response, ConPid, StreamRef, fin, Status, Header},
            #state{gun_pid=ConPid, sref=StreamRef} = State) ->
    Http = #{status => Status, header => Header, body => <<>>},
    NewState = handle_http_result(State#state{http=Http}),
    {noreply, NewState};
handle_info({gun_response, ConPid, StreamRef, nofin, Status, Header},
            #state{gun_pid=ConPid, sref=StreamRef} = State) ->
    NewState = State#state{http = #{status => Status,
                                    header => Header}},
    {noreply, NewState};
handle_info({gun_data, ConPid, StreamRef, nofin, Data},
            #state{gun_pid=ConPid, sref=StreamRef, http=Http} = State) ->
    OldBody = maps:get(body, Http, <<>>),
    NewBody = << OldBody/binary, Data/binary >>,
    NewState = State#state{http=maps:put(body, NewBody, Http)},
    {noreply, NewState};
handle_info({gun_data, ConPid, StreamRef, fin, Data},
            #state{gun_pid=ConPid, sref=StreamRef, http=Http} = State) ->
    OldBody = maps:get(body, Http, <<>>),
    Body = << OldBody/binary, Data/binary >>,
    NewState = handle_http_result(State#state{http=maps:put(body, Body, Http)}),
    {noreply, NewState};
handle_info({gun_error, ConPid, Reason}, #state{gun_pid=ConPid}= State ) ->
    handle_http_client_crash(Reason, State);
handle_info({gun_error, ConPid, _SRef, Reason}, #state{gun_pid=ConPid}=State)->
    handle_http_client_crash(Reason, State);
handle_info({'DOWN', MRef, process, ConPid, Reason},
            #state{gun_pid=ConPid, mref = MRef} = State) ->
    handle_http_client_crash(Reason, State);
handle_info(_Info, State) ->
    {noreply, State}.



terminate(_Reason, #state{gun_pid=GunPid}) ->
    gun:close(GunPid),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

retrieve_config(#state{config_ep = ConfigEndpoint}) ->
    oidcc_http_util:start_http(ConfigEndpoint).

retrieve_keys(#state{config = Config}) ->
    KeyEndpoint = maps:get(jwks_uri, Config, undefined),
    Error = {no_key_endpoint},
    start_http_if_possible(KeyEndpoint, Error).


register_client(#state{config = Config}) ->
    RegistrationEndpoint = maps:get(registration_endpoint, Config, undefined),
    Error = {no_registration_endpoint},
    start_http_if_possible(RegistrationEndpoint, Error).

start_http_if_possible(Endpoint, Error) ->
    case Endpoint of
        undefined ->
            {ok, undefined, undefined, undefined, Error};
        _ ->
            {ok, ConPid, MRef, Path} = oidcc_http_util:start_http(Endpoint),
            {ok, ConPid, MRef, Path, undefined}
    end.



handle_http_result(true, _,  Header, Body, config, State) ->
    handle_config(Body, Header, State);
handle_http_result(true, _,  Header, Body, keys, State) ->
    handle_keys(Body, Header, State);
handle_http_result(true, _, Header, Body, registration, State) ->
    handle_registration(Body, Header, State);
handle_http_result(false, Status, _Header, Body, Retrieve, State) ->
    trigger_config_retrieval(600000),
    State#state{error = {retrieving, Retrieve, Status, Body}}.


handle_http_result(#state{ retrieving = Retrieve, http =Http} = State) ->
    #{header := Header, status := Status, body := InBody} = Http,
    GoodStatus = (Status >= 200) and (Status < 300),
    NewState = stop_gun(State),
    {ok, Body} = oidcc_http_util:uncompress_body_if_needed(InBody, Header),
    handle_http_result(GoodStatus, Status, Header, Body, Retrieve, NewState).


create_config(#state{id = Id, desc = Desc, client_id = ClientId,
                     client_secret = ClientSecret, config_ep = ConfEp,
                     config=Config, keys = Keys, issuer = Issuer,
                     lasttime_updated = LastTimeUpdated, ready = Ready,
                     local_endpoint = LocalEndpoint, name = Name,
                     request_scopes = Scopes, meta_data = MetaData}) ->
    StateList = [{id, Id}, {name, Name}, {description, Desc},
                 {client_id, ClientId}, {client_secret, ClientSecret},
                 {config_endpoint, ConfEp}, {lasttime_updated, LastTimeUpdated},
                 {ready, Ready}, {local_endpoint, LocalEndpoint}, {keys, Keys},
                 {request_scopes, Scopes}, {issuer, Issuer},
                 {meta_data, MetaData}],
    maps:merge(Config, maps:from_list(StateList)).



handle_config(Data, _Header, #state{issuer=Issuer} = State) ->
    %TODO: implement update at expire data/time
    Config = decode_json(Data),
    ConfIssuer = maps:get(issuer, Config, undefined),

    case is_same_issuer(ConfIssuer, Issuer) of
        true ->
            ok = trigger_key_retrieval(),
            trigger_config_retrieval(3600000),
            State#state{config = Config, issuer=ConfIssuer};
        _ ->
            trigger_config_retrieval(600000),
            Error = {bad_issuer_config, Issuer, ConfIssuer, Data},
            State#state{error = Error, ready=false}
    end.


handle_keys(Data, _Header, State) ->
    %TODO: implement update at expire data/time or retrieval when needed
    KeyConfig=decode_json(Data),
    KeyList = maps:get(keys, KeyConfig, []),
    Keys = extract_supported_keys(KeyList, []),
    NewState = State#state{keys  = Keys, ready = false,
                           lasttime_updated = timestamp(), gun_pid = undefined},
    case length(Keys) > 0 of
        true ->
            ok = trigger_registration(),
            NewState;
        false ->
            trigger_config_retrieval(600000),
            NewState#state{error = {no_keys, Data}}
    end.

handle_registration(Data, _Header, State) ->
    %TODO: implement update at expire data/time or retrieval when needed
    MetaData=decode_json(Data),
    ClientId = maps:get(client_id, MetaData, undefined),
    ClientSecret = maps:get(client_secret, MetaData, undefined),
    ClientSecretExpire = maps:get(client_secret_expires_at, MetaData,
                                  undefined),
    case is_binary(ClientId) and is_binary(ClientSecret)
        and is_number(ClientSecretExpire) of
        true ->
            State#state{meta_data  = MetaData, client_id = ClientId,
                        client_secret = ClientSecret, ready = true,
                        lasttime_updated = timestamp(), gun_pid = undefined};
        false ->
            State#state{error=no_clientid, meta_data=MetaData, ready = false,
                        client_id=undefined, client_secret = undefined,
                        gun_pid = undefined}
    end.


decode_json(Data) ->
    try
        jsone:decode(Data, [{keys, attempt_atom}, {object_format, map}])
    catch error:badarg ->
            #{}
    end.


extract_supported_keys(Keys, List) ->
    extract_supported_keys(Keys, any, List).

extract_supported_keys([], _, List) ->
    List;
extract_supported_keys([#{ kty := Kty0} = Map|T], ListTypeIn, List) ->
    Kty = case Kty0 of
              <<"RSA">> -> rsa;
              _ ->  Kty0
          end,
    Alg0 = maps:get(alg, Map, undefined),
    Alg = case Alg0 of
              <<"RS256">> -> rs256;
              undefined -> undefined;
              _ -> unknown
          end,
    Kid = maps:get(kid, Map, undefined),
    Use0 = maps:get(use, Map, undefined),
    {Use, ListType} =
        case {Use0, ListTypeIn} of
              {<<"sig">>, any} -> {sign, combined};
              {<<"sig">>, combined} -> {sign, combined};
              {<<"enc">>, any} -> {enc, combined};
              {<<"enc">>, combined} -> {enc, combined};
              {undefined, any} -> {sign, pure_sign};
              {undefined, pure_sign} -> {sign, pure_sign};
              _ -> unknown
          end,
    Key =
        case Kty of
            rsa ->
                N0 = maps:get(n, Map),
                E0 = maps:get(e, Map),
                N1 = binary:decode_unsigned(base64url:decode(N0)),
                E1 = binary:decode_unsigned(base64url:decode(E0)),
                [E1, N1];
            _ ->
                unknown
        end,

    case (Use /= unknown) of
        true ->
            Update = #{kty => Kty, use => Use, alg => Alg,
                    key => Key, kid => Kid },
            Entry = maps:merge(Map, Update),
            extract_supported_keys(T, ListType, [Entry | List]);
        _ ->
            %% bad key, do exclude this provider
            []
    end;
extract_supported_keys(_, _, _) ->
    [].



handle_http_client_crash(_Reason, #state{config_tries=?MAX_TRIES} = State) ->
    {noreply, State};
handle_http_client_crash(_Reason, #state{config_tries=Tries} = State) ->
    trigger_config_retrieval(30000),
    NewState = State#state{gun_pid=undefined, retrieving=undefined, http=#{},
               config_tries=Tries+1},
    {noreply, NewState}.


trigger_config_retrieval() ->
    gen_server:cast(self(), retrieve_config).

trigger_config_retrieval(Time) ->
    timer:apply_after(Time, gen_server, cast, [self(), retrieve_config]).

trigger_key_retrieval() ->
    gen_server:cast(self(), retrieve_keys).

trigger_registration() ->
    gen_server:cast(self(), register_if_needed).

timestamp() ->
    erlang:system_time(seconds).

stop_gun(#state{gun_pid = Pid, mref = MonitorRef} =State) ->
    ok = oidcc_http_util:async_close(Pid, MonitorRef),
    State#state{gun_pid=undefined, retrieving=undefined, http=#{}}.


to_config_endpoint(IssuerOrEndpoint) ->
    Slash = <<"/">>,
    Config = <<".well-known/openid-configuration">>,
    ConfigS = << Slash/binary, Config/binary >>,
    Pos = byte_size(IssuerOrEndpoint) - 33,
    case binary:match(IssuerOrEndpoint, ConfigS) of
        {Pos, 33} ->
            Endpoint = IssuerOrEndpoint,
            Endpoint;
       _  ->
            Issuer = IssuerOrEndpoint,
            case binary:last(Issuer) of
                $/ -> << Issuer/binary, Config/binary>>;
                _ -> << Issuer/binary, ConfigS/binary>>
            end
    end.

config_ep_to_issuer(ConfigEp) ->
    [Issuer] = binary:split(ConfigEp, [<<"/.well-known/openid-configuration">>],
                 [trim_all, global]),
    Issuer.

is_same_issuer(Config, Issuer) ->
    Slash = <<"/">>,
    IssuerSlash = << Issuer/binary, Slash/binary >>,
    (Config =:= Issuer) or (Config =:= IssuerSlash).
