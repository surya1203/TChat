-module(client).
-author("Surya Giri | CWID: 10475010").
-export([main/1, initial_state/2]).

-include_lib("./defs.hrl").

-spec main(_InitialState) -> _.
-spec listen(_State) -> _.
-spec initial_state(_Nick, _GuiName) -> _InitialClientState.
-spec loop(_State, _Request, _Ref) -> _.
-spec do_join(_State, _Ref, _ChatName) -> _.
-spec do_leave(_State, _Ref, _ChatName) -> _.
-spec do_new_nick(_State, _Ref, _NewNick) -> _.
-spec do_new_incoming_msg(_State, _Ref, _SenderNick, _ChatName, _Message) -> _.

%% Receive messages from GUI and handle them accordingly
%% All handling can be done in loop(...)
main(InitialState) ->
    %% The client tells the server it is connecting with its initial nickname.
    %% This nickname is guaranteed unique system-wide as long as you do not assign a client
    %% the nickname in the form "user[number]" manually such that a new client happens
    %% to generate the same random number as you assigned to your client.
    whereis(server)!{self(), connect, InitialState#cl_st.nick},
    %% if running test suite, tell test suite that client is up
    case whereis(testsuite) of
	undefined -> ok;
	TestSuitePID -> TestSuitePID!{client_up, self()}
    end,
    %% Begins listening
    listen(InitialState).

%% This method handles all incoming messages from either the GUI or the
%% chatrooms that are not directly tied to an ongoing request cycle.
listen(State) ->
    receive
        {request, From, Ref, Request} ->
	    %% the loop method will return a response as well as an updated
	    %% state to pass along to the next cycle
            {Response, NextState} = loop(State, Request, Ref),
	    case Response of
		{dummy_target, Resp} ->
		    io:format("Use this for whatever you would like~n"),
		    From!{result, self(), Ref, {dummy_target, Resp}},
		    listen(NextState);
		%% if shutdown is received, terminate
		shutdown ->
		    ok_shutdown;
		%% if ok_msg_received, then we don't need to reply to sender.
		ok_msg_received ->
		    listen(NextState);
		%% otherwise, reply to sender with response
		_ ->
		    From!{result, self(), Ref, Response},
		    listen(NextState)
	    end
    end.

%% This function just initializes the default state of a client.
%% This should only be used by the GUI. Do not change it, as the
%% GUI code we provide depends on it.
initial_state(Nick, GUIName) ->
    #cl_st { gui = GUIName, nick = Nick, con_ch = maps:new() }.

%% ------------------------------------------
%% loop handles each kind of request from GUI
%% ------------------------------------------
loop(State, Request, Ref) ->
    case Request of
	%% GUI requests to join a chatroom with name ChatName
	{join, ChatName} ->
	    do_join(State, Ref, ChatName);

	%% GUI requests to leave a chatroom with name ChatName
	{leave, ChatName} ->
	    do_leave(State, Ref, ChatName);

	%% GUI requests to send an outgoing message Message to chatroom ChatName
	{outgoing_msg, ChatName, Message} ->
	    do_msg_send(State, Ref, ChatName, Message);

	%% GUI requests the nickname of client
	whoami ->
		whereis(list_to_atom(State#cl_st.gui)) ! {result, self(), Ref, State#cl_st.nick},
	    {ok_msg_received, State};

	%% GUI requests to update nickname to Nick
	{nick, Nick} ->
            do_new_nick(State, Ref, Nick);

	%% GUI requesting to quit completely
	quit ->
	    do_quit(State, Ref);

	%% Chatroom with name ChatName has sent an incoming message Message
	%% from sender with nickname SenderNick
	{incoming_msg, SenderNick, ChatName, Message} ->
	    do_new_incoming_msg(State, Ref, SenderNick, ChatName, Message);

	{get_state} ->
	    {{get_state, State}, State};

	%% Somehow reached a state where we have an unhandled request.
	%% Without bugs, this should never be reached.
	_ ->
	    io:format("Client: Unhandled Request: ~w~n", [Request]),
	    {unhandled_request, State}
    end.

%% executes `/join` protocol from client perspective
do_join(State, Ref, ChatName) ->
    case maps: find(ChatName, State#cl_st.con_ch) of 
		%% client already in the chatroom
		{ok, _Value} ->
			whereis(list_to_atom(State#cl_st.gui)) ! {result, self(), Ref, err},
			{ok_msg_received, State};
		%% client not in chatroom yet
		error ->
			whereis(server) ! {self(), Ref, join, ChatName},
			receive
				{ChatRoom, Ref, connect, History} ->
					whereis(list_to_atom(State#cl_st.gui)) ! {result, self(), Ref, History},
					NewState = State#cl_st{con_ch = maps:put(ChatName, ChatRoom, State#cl_st.con_ch)},
					{ok_msg_received, NewState}
			end
	end.

%% executes `/leave` protocol from client perspective
do_leave(State, Ref, ChatName) ->
    case maps: find(ChatName, State#cl_st.con_ch) of
		%% chatroom found
		{ok, _Value} ->
			Server = whereis(server),
			Server ! {self(), Ref, leave, ChatName},
			receive
				{Server, Ref, ack_leave} ->
					NewState = State#cl_st{con_ch = maps: remove(ChatName, State#cl_st.con_ch)},
					whereis(list_to_atom(State#cl_st.gui)) ! {result, self(), Ref, ok},
					{ok_msg_received, NewState}
			end;
		%% chatroom not found
		_ ->
			whereis(list_to_atom(State#cl_st.gui)) ! {result, self(), Ref, err},
			{ok_msg_received, State}
		end.

%% executes `/nick` protocol from client perspective
%% checking Nick against current nickname first
do_new_nick(State, Ref, NewNick) when NewNick == State#cl_st.nick ->
    whereis(list_to_atom(State#cl_st.gui)) ! {result, self(), Ref, err_same},
	{ok_msg_received, State};
%% when Nick is not the same as current nickname
do_new_nick(State, Ref, NewNick) ->
	Server = whereis(server),
	Server ! {self(), Ref, nick, NewNick},
	receive
		%% when nickname is already in use
		{Server, Ref, err_nick_used} ->
			whereis(list_to_atom(State#cl_st.gui)) ! {result, self(), Ref, err_nick_used},
			{ok_msg_received, State};
		%% nickname available
		{Server, Ref, ok_nick} ->
			whereis(list_to_atom(State#cl_st.gui)) ! {result, self(), Ref, ok_nick},
			{ok_msg_received, State#cl_st{nick = NewNick}}
		end.

%% executes send message protocol from client perspective
do_msg_send(State, Ref, ChatName, Message) ->
	%% searching for chatroom PID from connected chats list
    ChatroomPID = maps: get(ChatName, State#cl_st.con_ch),
	%% sending message
	ChatroomPID ! {self(), Ref, message, Message},
	%% receieve message sent confirmation
	receive
		{ChatroomPID, Ref, ack_msg} ->
			whereis(list_to_atom(State#cl_st.gui)) ! {result, self(), Ref, {msg_sent, State#cl_st.nick}}
	end,
	{ok_msg_received, State}.

%% executes new incoming message protocol from client perspective
do_new_incoming_msg(State, _Ref, CliNick, ChatName, Msg) ->
    %% pass message along to gui
    gen_server:call(list_to_atom(State#cl_st.gui), {msg_to_GUI, ChatName, CliNick, Msg}),
    {ok_msg_received, State}.

%% executes quit protocol from client perspective
do_quit(State, Ref) ->
    Server = whereis(server), 
	Server ! {self(), Ref, quit},
	%% receieve quit confirmation
	receive
		{Server, Ref, ack_quit} -> whereis(list_to_atom(State#cl_st.gui)) ! {self(), Ref, ack_quit}
	end,
	{ok_msg_received, State}.

