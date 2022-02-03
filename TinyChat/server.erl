-module(server).
-author("Surya Giri | CWID: 10475010").
-export([start_server/0]).

-include_lib("./defs.hrl").

-spec start_server() -> _.
-spec loop(_State) -> _.
-spec do_join(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_leave(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_new_nick(_State, _Ref, _ClientPID, _NewNick) -> _.
-spec do_client_quit(_State, _Ref, _ClientPID) -> _NewState.

start_server() ->
    catch(unregister(server)),
    register(server, self()),
    case whereis(testsuite) of
	undefined -> ok;
	TestSuitePID -> TestSuitePID!{server_up, self()}
    end,
    loop(
      #serv_st{
	 nicks = maps:new(), %% nickname map. client_pid => "nickname"
	 registrations = maps:new(), %% registration map. "chat_name" => [client_pids]
	 chatrooms = maps:new() %% chatroom map. "chat_name" => chat_pid
	}
     ).

loop(State) ->
    receive 
	%% initial connection
	{ClientPID, connect, ClientNick} ->
	    NewState =
		#serv_st{
		   nicks = maps:put(ClientPID, ClientNick, State#serv_st.nicks),
		   registrations = State#serv_st.registrations,
		   chatrooms = State#serv_st.chatrooms
		  },
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, join, ChatName} ->
	    NewState = do_join(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, leave, ChatName} ->
	    NewState = do_leave(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to register a new nickname
	{ClientPID, Ref, nick, NewNick} ->
	    NewState = do_new_nick(State, Ref, ClientPID, NewNick),
	    loop(NewState);
	%% client requests to quit
	{ClientPID, Ref, quit} ->
	    NewState = do_client_quit(State, Ref, ClientPID),
	    loop(NewState);
	{TEST_PID, get_state} ->
	    TEST_PID!{get_state, State},
	    loop(State)
    end.

%% executes join protocol from server perspective
do_join(ChatName, ClientPID, Ref, State) ->
	{ok, ClientNick} = maps: find(ClientPID, State#serv_st.nicks),
	case maps:find(ChatName, State#serv_st.chatrooms) of
		{ok, ChatroomPID} ->
			%% chat room already exists
			ChatroomPID ! {self(), Ref, register, ClientPID, ClientNick},
			Registrations = State#serv_st.registrations,
			State#serv_st{registrations = maps: update(ChatName, [ ClientPID | maps: get(ChatName, Registrations)], Registrations)};
		error -> 
			%% spawning new chatroom
			ChatroomPID = spawn(chatroom, start_chatroom, [ChatName]),
			ChatroomPID ! {self(), Ref, register, ClientPID, ClientNick},
			State#serv_st{chatrooms = maps: put(ChatName, ChatroomPID, State#serv_st.chatrooms), registrations = maps: put(ChatName, [ClientPID], State#serv_st.registrations)}
	end.

%% executes leave protocol from server perspective
do_leave(ChatName, ClientPID, Ref, State) ->
    {ok, ChatroomPID} = maps: find(ChatName, State#serv_st.chatrooms),
	Registrations = State#serv_st.registrations,
	%% removing client from list of registered chatrooms
	State#serv_st{registrations = maps: update(ChatName, lists: delete(ClientPID, maps:get(ChatName, Registrations)), Registrations)},
	ChatroomPID ! {self(), Ref, unregister, ClientPID},
	%% send leave confirmation
	ClientPID ! {self(), Ref, ack_leave},
	State.

%% executes new nickname protocol from server perspective
do_new_nick(State, Ref, ClientPID, NewNick) ->
	%% server checks if new nickname is already in use
    case lists: member(NewNick, maps: values(State#serv_st.registrations)) of
		%% nickname already in use
		true ->
			ClientPID ! {self(), Ref, err_nick_used},
			State;
		%% nickname available
		false ->
			State#serv_st{nicks = maps: update(ClientPID, NewNick, State#serv_st.nicks)},
			%% function for sending confirmation messages
			SendTo = fun(ChatName) ->
				case lists: member(ClientPID, maps: get(ChatName, State#serv_st.registrations)) of
					true ->
						maps: get(ChatName, State#serv_st.chatrooms) ! {self(), Ref, update_nick, ClientPID, NewNick};
					false ->
						do_nothing
					end
				end,
				%% sending confirmation messages
				lists: foreach(SendTo, maps: keys(State#serv_st.registrations)),
				ClientPID ! {self(), Ref, ok_nick},
				State
			end.



%% executes client quit protocol from server perspective
do_client_quit(State, Ref, ClientPID) ->
    %% removing client from nicknames
	State#serv_st{nicks = maps: remove(ClientPID, State#serv_st.registrations)},
	%% function for sending a quit acknowledgment 
	SendTo = fun(ChatName) ->
		case lists: member(ClientPID, maps: get(ChatName, State#serv_st.registrations)) of
			true ->
				maps: get(ChatName, State#serv_st.chatrooms) ! {self(), Ref, unregister, ClientPID};
			false ->
				do_nothing
			end
	end,
	%% sending quit confirmation
	lists: foreach(SendTo, maps: keys(State#serv_st.registrations)),
	ClientPID ! {self(), Ref, ack_quit},
	State.
