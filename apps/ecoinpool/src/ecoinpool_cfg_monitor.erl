
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ecoinpool.
%%
%% ecoinpool is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ecoinpool is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(ecoinpool_cfg_monitor).
-behaviour(gen_changes).

-include("ecoinpool_db_records.hrl").

-export([start_link/1]).

-export([init/1, handle_change/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

% Internal state record
-record(state, {
    subpools
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(ConfDb) ->
    gen_changes:start_link(?MODULE, ConfDb, [continuous, heartbeat, {filter, "doctypes/pool_only"}], []).

%% ===================================================================
%% Gen_Changes callbacks
%% ===================================================================

init([]) ->
    % Get already running subpools; useful if we were restarted
    ActiveSubpoolIds = ecoinpool_sup:running_subpools(),
    {ok, #state{subpools=sets:from_list(ActiveSubpoolIds)}}.

handle_change({ChangeProps}, State=#state{subpools=CurrentSubpools}) ->
    case proplists:get_value(<<"id">>, ChangeProps) of
        <<"configuration">> -> % The one and only root config document
            gen_changes:cast(self(), reload_root_config); % Schedule root config reload
        OtherId ->
            case sets:is_element(OtherId, CurrentSubpools) of
                true ->
                    gen_changes:cast(self(), {reload_subpool, OtherId});
                _ ->
                    io:format("ecoinpool_cfg_monitor:handle_change: Unhandled change: ~p~n", [OtherId])
            end
    end,
    {noreply, State}.

handle_call(_Message, _From, State=#state{}) ->
    {reply, error, State}.

handle_cast(reload_root_config, State=#state{subpools=CurrentSubpools}) ->
    % Load the root configuration, crash on error
    {ok, #configuration{active_subpools=ActiveSubpoolIds}} = ecoinpool_db:get_configuration(),
    
    CurrentSubpoolIds = sets:to_list(CurrentSubpools),
    
    lists:foreach( % Add new sub-pools
        fun (SubpoolId) ->
            gen_changes:cast(self(), {reload_subpool, SubpoolId})
        end,
        ActiveSubpoolIds -- CurrentSubpoolIds
    ),
    lists:foreach( % Remove deleted sub-pools
        fun (SubpoolId) ->
            gen_changes:cast(self(), {remove_subpool, SubpoolId})
        end,
        CurrentSubpoolIds -- ActiveSubpoolIds
    ),
    
    {noreply, State};

handle_cast({reload_subpool, SubpoolId}, State=#state{subpools=CurrentSubpools}) ->
    % Load the sub-pool configuration (here to check if valid)
    case ecoinpool_db:get_subpool_record(SubpoolId) of
        {ok, Subpool} ->
            % Check if sub-pool is already there
            case sets:is_element(SubpoolId, CurrentSubpools) of
                true -> % Yes: Reload the sub-pool, leave others as they are
                    ecoinpool_sup:reload_subpool(Subpool);
                _ -> % No: Add new sub-pool
                    ecoinpool_sup:start_subpool(SubpoolId)
            end,
            % Add (if not already there)
            {noreply, State#state{subpools=sets:add_element(SubpoolId, CurrentSubpools)}};
        
        {error, missing} -> % Stop if missing
            case sets:is_element(SubpoolId, CurrentSubpools) of
                true ->
                    ecoinpool_sup:stop_subpool(SubpoolId),
                    {noreply, State#state{subpools=sets:del_element(SubpoolId, CurrentSubpools)}};
                _ ->
                    {noreply, State}
            end;
        
        {error, invalid} -> % Ignore on invalid
            io:format("ecoinpool_cfg_monitor:reload_subpool: Invalid document for subpool ID: ~p.", [SubpoolId]),
            {noreply, State}
    end;

handle_cast({remove_subpool, SubpoolId}, State=#state{subpools=CurrentSubpools}) ->
    case sets:is_element(SubpoolId, CurrentSubpools) of
        true ->
            ecoinpool_sup:stop_subpool(SubpoolId),
            {noreply, State#state{subpools=sets:del_element(SubpoolId, CurrentSubpools)}};
        _ ->
            {noreply, State}
    end;

handle_cast(_Message, State=#state{}) ->
    io:format("ecoinpool_cfg_monitor:handle_cast: Unhandled message: ~p~n", [_Message]),
    {noreply, State}.

handle_info(_Message, State=#state{}) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.