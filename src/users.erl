-module(users).
-include_lib("kvs/include/users.hrl").
-include_lib("kvs/include/groups.hrl").
-include_lib("kvs/include/accounts.hrl").
-include_lib("kvs/include/log.hrl").
-include_lib("mqs/include/mqs.hrl").
-compile(export_all).

register(#user{username=U, email=Email, facebook_id = FbId} = RegisterData0) ->
    FindUser = case check_username(U, FbId) of
        {error, E} -> {error, E};
        {ok, NewName} -> case users:get({email, Email}) of
            {error, _} -> {ok, NewName};
            {ok, _} -> {error, email_taken} end end,

    FindUser2 = case FindUser of
        {ok, UserName} -> case groups:get(UserName) of
            {error, _} -> {ok, UserName};
            _ -> {error, username_taken} end;
        A -> A end,

    case FindUser2 of
        {ok, Name} -> process_register(RegisterData0#user{username=Name});
        {error, username_taken} -> {error, user_exist};
        {error, email_taken} ->    {error, email_taken} end.

process_register(#user{username=U} = RegisterData0) ->
    HashedPassword = case RegisterData0#user.password of
        undefined -> undefined;
        PlainPassword -> utils:sha(PlainPassword) end,
    RegisterData = RegisterData0#user {
        feed     = kvs:feed_create(),
        direct   = kvs:feed_create(),
        pinned   = kvs:feed_create(),
        starred  = kvs:feed_create(),
        password = HashedPassword },

    kvs:put(RegisterData),
    accounts:create_account(U),
    {ok, DefaultQuota} = kvs:get(config, "accounts/default_quota",  300),
    accounts:transaction(U, quota, DefaultQuota, #tx_default_assignment{}),
    init_mq(U, []),
    {ok, U}.

check_username(Name, FbId) ->
    case users:get(Name) of
        {error, notfound} -> {ok, Name};
        {ok, User} when FbId =/= undefined -> check_username(User#user.username  ++ integer_to_list(crypto:rand_uniform(0,10)), FbId);
        {ok, _}-> {error, username_taken} end.

delete(UserName) ->
    case users:get(UserName) of
        {ok, User} -> GIds = groups:list_groups_per_user(UserName),
                      [nsx_msg:notify(["subscription", "user", UserName, "remove_from_group"], {GId}) || GId <- GIds],
                      F2U = [ {MeId, FrId} || #subscription{who = MeId, whom = FrId} <- subscriptions(User) ],
                      [ unsubscribe(MeId, FrId) || {MeId, FrId} <- F2U ],
                      [ unsubscribe(FrId, MeId) || {MeId, FrId} <- F2U ],
                      kvs:delete(user_status, UserName),
                      kvs:delete(user, UserName),
                      {ok, User};
                 E -> E end.

get({username, UserName}) -> kvs:user_by_username(UserName);
get({facebook, FBId}) -> kvs:user_by_facebook_id(FBId);
get({email, Email}) -> kvs:user_by_email(Email);
get(UId) -> kvs:get(user, UId).

subscribe(Who, Whom) ->
    case is_user_blocked(Who, Whom) of
        false -> Record = #subscription{key={Who,Whom}, who = Who, whom = Whom},
                 kvs:put(Record),
                 subscribe_user_mq(user, Who, Whom);
        true  -> do_nothing
    end.

unsubscribe(Who, Whom) ->
    case subscribed(Who, Whom) of
        true  -> kvs:delete(subscription, {Who, Whom}),
                 remove_subscription_mq(user, Who, Whom);
        false -> skip end.

subscriptions(undefined)-> [];
subscriptions(#user{username = UId}) -> subscriptions(UId);
subscriptions(UId) when is_list(UId) -> lists:sort( kvs:all_by_index(subs, <<"subs_who_bin">>, list_to_binary(UId)) ).

subscribed(Who, Whom) ->
    case kvs:get(subscription, {Who, Whom}) of
        {ok, _} -> true;
        _ -> false end.

block(Who, Whom) ->
    ?INFO("~w:block_user/2 Who=~p Whom=~p", [?MODULE, Who, Whom]),
    unsubscribe(Who, Whom),
    kvs:block_user(Who, Whom),
    nsx_msg:notify_user_block(Who, Whom).

unblock(Who, Whom) ->
    ?INFO("~w:unblock_user/2 Who=~p Whom=~p", [?MODULE, Who, Whom]),
    kvs:unblock_user(Who, Whom),
    nsx_msg:notify_user_unblock(Who, Whom).

blocked_users(UserId) -> kvs:list_blocks(UserId).

get_blocked_users_feed_id(UserId) ->
    UsersId = kvs:list_blocks(UserId),
    Users = kvs:select(user, fun(#user{username=U})-> lists:member(U, UsersId) end),
    {UsersId, [Fid || #user{feed=Fid} <- Users]}.

is_user_blocked(Who, Whom) -> kvs:is_user_blocked(Who,Whom).

update_user(#user{username=UId,name=Name,surname=Surname} = NewUser) ->
    OldUser = case kvs:get(user,UId) of
        {error,notfound} -> NewUser;
        {ok,#user{}=User} -> User
    end,
    kvs:put(NewUser),
    case Name==OldUser#user.name andalso Surname==OldUser#user.surname of
        true -> ok;
        false -> kvs:update_user_name(UId,Name,Surname)
    end.

subscribe_user_mq(Type, MeId, ToId) -> process_subscription_mq(Type, add, MeId, ToId).
remove_subscription_mq(Type, MeId, ToId) -> process_subscription_mq(Type, delete, MeId, ToId).
process_subscription_mq(Type, Action, MeId, ToId) ->
    {ok, Channel} = mqs:open([]),
    Routes = case Type of
                 user -> rk_user_feed(ToId);
                 group -> rk_group_feed(ToId)
             end,
    case Action of
        add -> bind_user_exchange(Channel, MeId, Routes);
        delete -> catch(unbind_user_exchange(Channel, MeId, Routes))
    end,
    mqs_channel:close(Channel).

init_mq(User, Groups) ->
    ?INFO("~p init mq. users: ~p", [User, Groups]),
    UserExchange = ?USER_EXCHANGE(User),
    ExchangeOptions = [{type, <<"fanout">>}, durable, {auto_delete, false}],
    {ok, Channel} = mqs:open([]),
    ?INFO("Cration Exchange: ~p,",[{Channel,UserExchange,ExchangeOptions}]),
    mqs_channel:create_exchange(Channel, UserExchange, ExchangeOptions), ?INFO("Created OK"),
    Relations = build_user_relations(User, Groups),
    [bind_user_exchange(Channel, User, RK) || RK <- [rk([feed, delete, User])|Relations]],
    mqs_channel:close(Channel),
    ok.

init_mq_for_user(User) -> init_mq(User, groups:list_groups_per_user(User) ).

build_user_relations(User, Groups) ->
    %% Feed Keys. Subscribe for self events, system and groups events
    %% feed.FeedOwnerType.FeedOwnerId.ElementType.ElementId.Action
    %% feed.system.ElementType.Action
    [rk_user_feed(User),
     rk( [db, user, User, put] ),
     rk( [subscription, user, User, add_to_group]),
     rk( [subscription, user, User, remove_from_group]),
     rk( [subscription, user, User, leave_group]),
     rk( [login, user, User, update_after_login]),
     rk( [likes, user, User, add_like]),
     rk( [personal_score, user, User, add]),
     rk( [feed, user, User, count_entry_in_statistics] ),
     rk( [feed, user, User, count_comment_in_statistics] ),
     rk( [feed, user, User, post_note] ),
     rk( [subscription, user, User, subscribe_user]),
     rk( [subscription, user, User, remove_subscribe]),
     rk( [subscription, user, User, set_user_game_status]),
     rk( [subscription, user, User, update_user]),
     rk( [subscription, user, User, block_user]),
     rk( [subscription, user, User, unblock_user]),
     rk( [affiliates, user, User, create_affiliate]),
     rk( [affiliates, user, User, delete_affiliate]),
     rk( [affiliates, user, User, enable_to_look_details]),
     rk( [affiliates, user, User, disable_to_look_details]),
     rk( [purchase, user, User, set_purchase_external_id]),
     rk( [purchase, user, User, set_purchase_state]),
     rk( [purchase, user, User, set_purchase_info]),
     rk( [purchase, user, User, add_purchase]),
     rk( [transaction, user, User, add_transaction]),
     rk( [invite, user, User, add_invite_to_issuer]),
     rk( [tournaments, user, User, create]),
     rk( [tournaments, user, User, create_and_join]),
     rk( [gifts, user, User, buy_gift]),
     rk( [gifts, user, User, give_gift]),
     rk( [gifts, user, User, mark_gift_as_deliving]),
     rk( [feed, system, '*', '*']) |
     [rk_group_feed(G) || G <- Groups]].

bind_user_exchange(Channel, User, RoutingKey) -> {bind, RoutingKey, mqs_channel:bind_exchange(Channel, ?USER_EXCHANGE(User), ?NOTIFICATIONS_EX, RoutingKey)}.
unbind_user_exchange(Channel, User, RoutingKey) -> {unbind, RoutingKey, mqs_channel:unbind_exchange(Channel, ?USER_EXCHANGE(User), ?NOTIFICATIONS_EX, RoutingKey)}.
bind_group_exchange(Channel, Group, RoutingKey) -> {bind, RoutingKey, mqs_channel:bind_exchange(Channel, ?GROUP_EXCHANGE(Group), ?NOTIFICATIONS_EX, RoutingKey)}.
unbind_group_exchange(Channel, Group, RoutingKey) -> {unbind, RoutingKey, mqs_channel:unbind_exchange(Channel, ?GROUP_EXCHANGE(Group), ?NOTIFICATIONS_EX, RoutingKey)}.

init_mq_for_group(Group) ->
    GroupExchange = ?GROUP_EXCHANGE(Group),
    ExchangeOptions = [{type, <<"fanout">>},
                       durable,
                       {auto_delete, false}],   
    {ok, Channel} = mqs:open([]),
    ok = mqs_channel:create_exchange(Channel, GroupExchange, ExchangeOptions),
    Relations = build_group_relations(Group),
    [bind_group_exchange(Channel, Group, RK) || RK <- Relations],
    mqs_channel:close(Channel),
    ok.

build_group_relations(Group) ->
    [
        rk( [db, group, Group, put] ),
        rk( [db, group, Group, update_group] ),
        rk( [db, group, Group, remove_group] ),
        rk( [likes, group, Group, add_like]),   % for comet mostly
        rk( [feed, delete, Group] ),
        rk( [feed, group, Group, '*', '*', '*'] )
    ].


rk(List) -> mqs_lib:list_to_key(List).
rk_user_feed(User) -> rk([feed, user, User, '*', '*', '*']).
rk_group_feed(Group) -> rk([feed, group, Group, '*', '*', '*']).

retrieve_connections(Id,Type) ->
    Friends = case Type of 
                  user -> users:list_subscr_usernames(Id);
                     _ -> groups:list_group_members(Id) end,
    case Friends of
	[] -> [];
	Full -> Sub = lists:sublist(Full, 10),
                case Sub of
                     [] -> [];
                      _ -> Data = [begin case kvs:get(user,Who) of
                                       {ok,User} -> RealName = users:user_realname_user(User),
                                                    Paid = accounts:user_paid(Who),
                                                    {Who,Paid,RealName};
				               _ -> undefined end end || Who <- Sub],
			   [X||X<-Data, X/=undefined] end end.
