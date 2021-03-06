%%% @doc Server-Sent Event handler for Cowboy
-module(lasse_handler).

-export([
         init/3,
         info/3,
         terminate/3
        ]).

-export([
         notify/2
        ]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Records
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state,
        {
          module :: module(),
          state :: any()
        }).
-type state() :: #state{}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Behavior definition
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type event() ::
    #{ id => binary()
     , event => binary()
     , data => binary()
     , retry => binary()
     , comment | '' => binary()
     }.

-type result() ::
    {'send', Event :: event(), NewState :: any()} |
    {'nosend', NewState :: any()} |
    {'stop', NewState :: any()}.

-export_type([event/0, result/0]).

-callback init(InitArgs :: any(),
               LastEvtId::undefined | binary(),
               Req::cowboy_req:req()) ->
    {ok, NewReq :: cowboy_req:req(), State :: any()} |
    {ok, NewReq :: cowboy_req:req(), Events :: [event()], State :: any()} |
    {no_content, NewReq :: cowboy_req:req(), State :: any()} |
    {
      shutdown,
      StatusCode :: cowboy:http_status(),
      Headers :: cowboy:http_headers(),
      Body :: iodata(),
      NewReq :: cowboy_req:req(),
      State :: any()
    }.

-callback handle_notify(Msg :: any(), State :: any()) ->
    result().

-callback handle_info(Msg :: any(), State :: any()) ->
    result().

-callback handle_error(Msg :: any(), Reason :: any(), State :: any()) ->
    any().

-callback terminate(Reason :: any(),
                    Req :: cowboy_req:req(),
                    State :: any()) ->
    any().

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Cowboy callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type lasse_handler_options() ::
    [module()] |
    #{ module => module()
     , init_args => any()
     }.

-spec init(any(), cowboy_req:req(), lasse_handler_options()) ->
    {loop, cowboy_req:req(), state()}.
init(Transport, Req, [Module]) when is_atom(Module) ->
    init(Transport, Req, #{module => Module});
init(_Transport, Req, Opts) ->
    try
      #{module := Module} = Opts,
      InitArgs = maps:get(init_args, Opts, []),
      {LastEventId, Req} = cowboy_req:header(<<"last-event-id">>, Req),
      InitResult = Module:init(InitArgs, LastEventId, Req),
      handle_init(InitResult, Module)
    catch
      _:{badmatch, _} ->
        throw(module_option_missing)
    end.

-spec info(term(), cowboy_req:req(), state()) ->
    {ok|loop, cowboy_req:req(), state()}.
info({message, Msg}, Req, State) ->
    Module = State#state.module,
    ModuleState = State#state.state,
    Result = Module:handle_notify(Msg, ModuleState),
    process_result(Result, Req, State);
info(Msg, Req, State) ->
    Module = State#state.module,
    ModuleState = State#state.state,
    Result = Module:handle_info(Msg, ModuleState),
    process_result(Result, Req, State).

-spec terminate(term(), cowboy_req:req(), state()) -> ok.
terminate(Reason, Req, State = #state{}) ->
    Module = State#state.module,
    ModuleState = State#state.state,
    Module:terminate(Reason, Req, ModuleState),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec notify(atom() | pid(), term()) -> ok.
notify(Pid, Msg) ->
    Pid ! {message, Msg},
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Helper functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
handle_init({ok, Req, State}, Module) ->
    handle_init({ok, Req, [], State}, Module);
handle_init({ok, Req, InitialEvents, State}, Module) ->
    case cowboy_req:method(Req) of
        {<<"GET">>, Req1} ->
            % "no-cache recommended to prevent caching of event data.
            Headers = [{<<"content-type">>, <<"text/event-stream">>},
                       {<<"cache-control">>, <<"no-cache">>}],
            {ok, Req2} = cowboy_req:chunked_reply(200, Headers, Req1),

            lists:foreach(
              fun(Event) -> ok = send_event(Event, Req2) end,
              InitialEvents
             ),

            {loop, Req2, #state{module = Module, state = State}};
        {_OtherMethod, _} ->
            Headers = [{<<"content-type">>, <<"text/html">>}],
            StatusCode = 405, % Method not Allowed
            {ok, Req1} = cowboy_req:reply(StatusCode, Headers, Req),
            {shutdown, Req1, #state{module = Module}}
    end;
handle_init({no_content, Req, State}, Module) ->
    {ok, Req1} = cowboy_req:reply(204, [], Req),

    {shutdown, Req1, #state{module = Module, state = State}};
handle_init({shutdown, StatusCode, Headers, Body, Req, State}, Module) ->
    {ok, Req1} = cowboy_req:reply(StatusCode, Headers, Body, Req),

    {shutdown, Req1, #state{module = Module, state = State}}.

process_result({send, Event, NewState}, Req, State) ->
    case send_event(Event, Req) of
        {error, Reason} ->
            Module = State#state.module,
            ModuleState = State#state.state,
            ErrorNewState = Module:handle_error(Event, Reason, ModuleState),
            {ok, Req, State#state{state = ErrorNewState}};
        ok ->
            {loop, Req, State#state{state = NewState}}
    end;
process_result({nosend, NewState}, Req, State) ->
    {loop, Req, State#state{state = NewState}};
process_result({stop, NewState}, Req, State) ->
    {ok, Req, State#state{state = NewState}}.

send_event(Event, Req) ->
    EventMsg = build_event(Event),
    cowboy_req:chunk(EventMsg, Req).

build_event(Event) ->
    [build_comment(maps:get(comment, Event, undefined)),
     build_comment(maps:get('', Event, undefined)),
     build_field(<<"id: ">>, maps:get(id, Event, undefined)),
     build_field(<<"event: ">>, maps:get(event, Event, undefined)),
     build_data(maps:get(data, Event, undefined)),
     build_field(<<"retry: ">>, maps:get(retry, Event, undefined)),
     <<"\n">>].

build_comment(undefined) ->
    [];
build_comment(Comment) ->
    [[<<": ">>, X, <<"\n">>] || X <- binary:split(Comment, <<"\n">>, [global])].

build_field(_, undefined) ->
    [];
build_field(Name, Value) ->
    [Name, Value, <<"\n">>].

build_data(undefined) ->
    throw(data_required);
build_data(Data) ->
    [[<<"data: ">>, X, <<"\n">>]
    || X <- binary:split(Data, <<"\n">>, [global])].
