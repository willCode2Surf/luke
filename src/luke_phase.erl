%% Copyright (c) 2010 Basho Technologies, Inc.  All Rights Reserved.

%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at

%%   http://www.apache.org/licenses/LICENSE-2.0

%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

-module(luke_phase).

-behaviour(gen_fsm).

-define(BUFFER_INPUT_CHECK, 1000).
-define(MAX_BUFFERED_INPUTS, 500).

%% API
-export([start_link/7,
         complete/0,
         partners/3]).

%% Behaviour
-export([behaviour_info/1]).

%% States
-export([executing/2,
         executing/3]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-record(state, {id,
                mod,
                modstate,
                converge=false,
                accumulate=false,
                lead_partner,
                partners,
                next_phases,
                done_count=1,
                input_count=0,
                flow,
                flow_timeout}).

behaviour_info(callbacks) ->
  [{init, 1},
   {handle_timeout, 1},
   {handle_input, 3},
   {handle_input_done, 1},
   {handle_sync_event, 3},
   {handle_event, 2},
   {handle_info, 2},
   {terminate, 2}];
behaviour_info(_) ->
    undefined.

start_link(PhaseMod, Id, Behaviors, NextPhases, Flow, Timeout, PhaseArgs) ->
    gen_fsm:start_link(?MODULE, [Id, PhaseMod, Behaviors, NextPhases, Flow,
                                 Timeout, PhaseArgs], []).

complete() ->
    gen_fsm:send_event(self(), complete).

partners(PhasePid, Leader, Partners) ->
    gen_fsm:send_event(PhasePid, {partners, Leader, Partners}).

init([Id, PhaseMod, Behaviors, NextPhases, Flow, Timeout, PhaseArgs]) ->
    case PhaseMod:init(PhaseArgs) of
        {ok, ModState} ->
            Accumulate = lists:member(accumulate, Behaviors),
            Converge = lists:member(converge, Behaviors),
            {ok, executing, #state{id=Id, mod=PhaseMod, modstate=ModState, next_phases=NextPhases,
                                   flow=Flow, accumulate=Accumulate, converge=Converge, flow_timeout=Timeout}};
        {stop, Reason} ->
            {stop, Reason}
    end.

executing({partners, Lead0, Partners0}, #state{converge=true}=State) when is_list(Partners0) ->
    Me = self(),
    Lead = case Lead0 of
               Me ->
                   undefined;
               _ ->
                   erlang:link(Lead0),
                   Lead0
           end,
    Partners = lists:delete(self(), Partners0),
    DoneCount = if
                    Lead =:= undefined ->
                        length(Partners) + 1;
                    true ->
                        1
                end,
    {next_state, executing, State#state{lead_partner=Lead, partners=Partners, done_count=DoneCount}};
executing({partners, _, _}, State) ->
    {stop, {error, no_convergence}, State};
executing({inputs, Input}, #state{mod=PhaseMod, modstate=ModState, flow_timeout=Timeout}=State) ->
    handle_callback(async, PhaseMod:handle_input(Input, ModState, Timeout), State);
executing(inputs_done, #state{mod=PhaseMod, modstate=ModState, done_count=DoneCount0}=State) ->
    case DoneCount0 - 1 of
        0 ->
            handle_callback(async, PhaseMod:handle_input_done(ModState), State#state{done_count=0});
        DoneCount ->
            {next_state, executing, State#state{done_count=DoneCount}}
    end;
executing(complete, #state{lead_partner=Leader}=State) when is_pid(Leader) ->
    luke_phases:send_inputs_done(Leader),
    {stop, normal, State};
executing(complete, #state{flow=Flow, next_phases=Next}=State) ->
    case Next of
        undefined ->
            luke_phases:send_flow_complete(Flow);
        _ ->
            luke_phases:send_inputs_done(Next)
    end,
    {stop, normal, State};
executing(timeout, #state{mod=Mod, modstate=ModState}=State) ->
    handle_callback(async, Mod:handle_timeout(ModState), State);
executing(timeout, State) ->
    {stop, normal, State};
executing(Event, #state{mod=PhaseMod, modstate=ModState}=State) ->
    handle_callback(async, PhaseMod:handle_event(Event, ModState), State).


executing({inputs, Input}, _From, #state{mod=PhaseMod, modstate=ModState, flow_timeout=Timeout}=State) ->
    handle_callback(sync, PhaseMod:handle_input(Input, ModState, Timeout), State);
executing(Event, From, #state{mod=PhaseMod, modstate=ModState}=State) ->
    case PhaseMod:handle_sync_event(Event, From, ModState) of
        {reply, Reply, NewModState} ->
            {reply, Reply, executing, State#state{modstate=NewModState}};
        {noreply, NewModState} ->
            {next_state, executing, State#state{modstate=NewModState}};
        {stop, Reason, Reply, NewModState} ->
            {stop, Reason, Reply, State#state{modstate=NewModState}};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#state{modstate=NewModState}}
    end.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, ignored, StateName, State}.

handle_info(timeout, executing, #state{mod=Mod, modstate=ModState}=State) ->
    handle_callback(async, Mod:handle_timeout(ModState), State);
handle_info(Info, _StateName, #state{mod=PhaseMod, modstate=ModState}=State) ->
    handle_callback(async, PhaseMod:handle_info(Info, ModState), State).

terminate(Reason, _StateName, #state{mod=PhaseMod, modstate=ModState}) ->
    PhaseMod:terminate(Reason, ModState),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% Internal functions
%% Handle callback module return values
handle_callback(Type, {no_output, NewModState}, State) ->
    State1 = State#state{modstate=NewModState},
    case Type of
        async ->
            {next_state, executing, State1};
        sync ->
            {reply, ok, executing, State1}
    end;
handle_callback(Type, {no_output, NewModState, PhaseTimeout},
                #state{flow_timeout=Timeout}=State) when PhaseTimeout < Timeout ->
    State1 = State#state{modstate=NewModState},
    case Type of
        async ->
            {next_state, executing, State1, PhaseTimeout};
        sync ->
            {reply, ok, executing, State1, PhaseTimeout}
    end;
handle_callback(Type, {output, Output, NewModState}, State) ->
    State1 = route_output(Output, State),
    State2 = State1#state{modstate=NewModState},
    case Type of
        async ->
            {next_state, executing, State2};
        sync ->
            {reply, ok, executing, State2}
    end;
handle_callback(Type, {output, Output, NewModState, PhaseTimeout},
                #state{flow_timeout=Timeout}=State) when PhaseTimeout < Timeout ->
    State1 = route_output(Output, State),
    State2 = State1#state{modstate=NewModState},
    case Type of
        async ->
            {next_state, executing, State2, PhaseTimeout};
        sync ->
            {reply, ok, executing, State2, PhaseTimeout}
    end;
handle_callback(_Type, {stop, Reason, NewModState}, State) ->
    {stop, Reason, State#state{modstate=NewModState}};
handle_callback(_Type, BadValue, _State) ->
  throw({error, {bad_return, BadValue}}).

%% Route output to lead when converging
%% Accumulation is ignored for non-leads of converging phases
%% since all accumulation is performed in the lead process
route_output(Output, #state{converge=true, lead_partner=Lead}=State) when is_pid(Lead) ->
    propagate_inputs([Lead], Output),
    State;

%% Send output to flow for accumulation and propagate as inputs
%% to the next phase. Accumulation is only true for the lead
%% process of a converging phase
route_output(Output, #state{id=Id, converge=true, accumulate=Accumulate, lead_partner=undefined,
                            flow=Flow}=State) ->
    if
        Accumulate =:= true ->
            luke_phases:send_flow_results(Flow, Id, Output);
        true ->
            ok
    end,
    propagate_inputs(State, Output);

%% Route output to the next phase. Accumulate output
%% to the flow if accumulation is turned on.
route_output(Output, #state{id=Id, converge=false, accumulate=Accumulate, flow=Flow} = State) ->
    if
        Accumulate =:= true ->
            luke_phases:send_flow_results(Flow, Id, Output);
        true ->
            ok
    end,
    propagate_inputs(State, Output).

propagate_inputs(#state{next_phases=undefined}=State, _Results) ->
    State;
propagate_inputs(#state{next_phases=Next, input_count=InputCount0}=State, Results) ->
    {InputCount, UseSync} = case InputCount0 of
                                 ?BUFFER_INPUT_CHECK ->
                                     {0, needs_sync(Next)};
                                 _ ->
                                     {InputCount0 + 1, false}
                             end,
    RotatedNext = case UseSync of
                      true ->
                          luke_phases:send_sync_inputs(Next, Results, infinity);
                      false ->
                          luke_phases:send_inputs(Next, Results)
                  end,
    State#state{next_phases=RotatedNext, input_count=InputCount};
propagate_inputs(Targets, Results) ->
    luke_phases:send_inputs(Targets, Results).

needs_sync([]) ->
    false;
needs_sync([H]) ->
    {message_queue_len, Len} = erlang:process_info(H, message_queue_len),
    Len > ?MAX_BUFFERED_INPUTS;
needs_sync([H|T]) ->
    {message_queue_len, Len} = erlang:process_info(H, message_queue_len),
    case Len > ?MAX_BUFFERED_INPUTS of
        true ->
            true;
        false ->
            needs_sync(T)
    end.
