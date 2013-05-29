-module(meetings).
-include_lib("kvs/include/users.hrl").
-include_lib("kvs/include/meetings.hrl").
-compile(export_all).

create_team(Name) ->
    TID = kvs:next_id("team",1),
    ok = kvs:put(Team = #team{id=TID,name=Name}),
    TID.

create(UID, Name) -> create(UID, Name, "", date(), time(), 100, 100, undefined, pointing, game_okey, standard, 8, slow).
create(UID, Name, Desc, Date, Time, Players, Quota, Awards, Type, Game, Mode, Tours, Speed) ->
    NodeAtom = nsx_opt:get_env(store,game_srv_node,'game@doxtop.cc'),
    TID = rpc:call(NodeAtom, game_manager, gen_game_id, []),

    CTime = erlang:now(),
    ok = kvs:put(#meeting{name = Name,
                                   id = TID,
                                   description = Desc,
                                   quota = Quota,
                                   players_count = Players,
                                   start_date = Date,
                                   awards = Awards,
                                   creator = UID,
                                   created = CTime,
                                   game_type = Game,
                                   game_mode = Mode,
                                   type = Type,
                                   tours = Tours,
                                   speed = Speed,
                                   start_time = Time,
                                   status = created,
                                   owner = UID}),

    TID.

get(TID) ->
    case kvs:get(meeting, TID) of
        {ok, Tournament} -> Tournament;
        {error, not_found} -> #meeting{};
        {error, notfound} -> #meeting{}
    end.

start(_TID) -> ok.
join(UID, TID) -> kvs:join_tournament(UID, TID).
remove(UID, TID) -> kvs:leave_tournament(UID, TID).
waiting_player(TID) -> kvs:tournament_pop_waiting_player(TID).
joined_users(TID) -> kvs:tournament_waiting_queue(TID).
user_tournaments(UID) -> kvs:user_tournaments(UID).
user_joined(TID, UID) -> 
    AllJoined = [UId || #play_record{who = UId} <- joined_users(TID)],
    lists:member(UID, AllJoined).
all() -> kvs:all(tournament).
user_is_team_creator(_UID, _TID) -> true.
list_users_per_team(_TeamID) -> [].
destroy(TID) -> kvs:delete_by_index(play_record, <<"play_record_tournament_bin">>, TID),
                          kvs:delete(tournament,TID).
clear() -> [destroy(T#meeting.id) || T <- kvs:all(meeting)].
lost() -> lists:usort([erlang:element(3, I) || I <- kvs:all(play_record)]).
fake_join(TID) -> [meetings:join(auth:ima_gio2(X),TID)||X<-lists:seq(1,30)].
