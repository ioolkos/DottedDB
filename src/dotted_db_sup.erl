-module(dotted_db_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init(_Args) ->
    VMaster = { dotted_db_vnode_master,
                  {riak_core_vnode_master, start_link, [dotted_db_vnode]},
                  permanent, 5000, worker, [riak_core_vnode_master]},

    
    WriteFSMs = {dotted_db_put_fsm_sup,
                 {dotted_db_put_fsm_sup, start_link, []},
                 permanent, infinity, supervisor, [dotted_db_put_fsm_sup]},

    GetFSMs = {dotted_db_get_fsm_sup,
               {dotted_db_get_fsm_sup, start_link, []},
               permanent, infinity, supervisor, [dotted_db_get_fsm_sup]},

    SyncFSMs = {dotted_db_sync_fsm_sup,
               {dotted_db_sync_fsm_sup, start_link, []},
               permanent, infinity, supervisor, [dotted_db_sync_fsm_sup]},

    CoverageFSMs = {dotted_db_coverage_fsm_sup,
                    {dotted_db_coverage_fsm_sup, start_link, []},
                    permanent, infinity, supervisor, [dotted_db_coverage_fsm_sup]},

    { ok,
        { {one_for_one, 5, 10},
          [VMaster, WriteFSMs, GetFSMs, SyncFSMs, CoverageFSMs]}}.
