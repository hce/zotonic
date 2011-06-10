%% @doc SMTP server for handling bounced messages.
%%      Code based on the example callback module supplied 
%%      with gen_smtp. 
%%      Original author: Andrew Thompson (andrew@hijacked.us)
%% @author Atilla Erdodi <atilla@maximonster.com>
%% @copyright 2010 Maximonster Interactive Things

-module(z_email_bounce_server).
-behaviour(gen_smtp_server_session).

-include_lib("zotonic.hrl").

-export([start_link/0]).

-export([init/4, handle_HELO/2, handle_EHLO/3, handle_MAIL/2, handle_MAIL_extension/2,
         handle_RCPT/2, handle_RCPT_extension/2, handle_DATA/4, handle_RSET/1, handle_VRFY/2,
         handle_other/3, code_change/3, terminate/2]).

-record(state,
	{
            options = [] :: list()
	}).
        

start_link() ->
    %% Collect the configuration args of the bounce server 
    Args1 = case z_config:get(smtp_bounce_domain) of
        undefined -> [];
        BounceDomain -> [{domain, BounceDomain}]
    end,	
    Args2 = case z_config:get(smtp_bounce_ip) of
        undefined -> [];
        any -> [{address, {0,0,0,0}} | Args1];
        BounceIp -> 
            {ok, Address} = inet:getaddr(BounceIp, inet),
            [{address, Address} | Args1]
    end,	
    Args3 = case z_config:get(smtp_bounce_port) of
        undefined -> Args2;
        BouncePort -> [{port, BouncePort} | Args2]
    end,
    start_link([Args3]).

start_link(Args) when is_list(Args) ->
    gen_smtp_server:start_link({local, ?MODULE}, ?MODULE, Args).

-spec init(Hostname :: binary(), SessionCount :: non_neg_integer(), Address :: tuple(), Options :: list()) -> {'ok', string(), #state{}} | {'stop', any(), string()}.
init(Hostname, SessionCount, _Address, Options) ->
    case SessionCount > 20 of
        false ->
            Banner = io_lib:format("~s ESMTP Zotonic ~s", [Hostname, ?ZOTONIC_VERSION]),
            State = #state{options = Options},
            {ok, Banner, State};
        true ->
            error_logger:warning_msg("SMTP Connection limit exceeded~n"),
            {stop, normal, io_lib:format("421 ~s is too busy to accept mail right now", [Hostname])}
    end.

-spec handle_HELO(Hostname :: binary(), State :: #state{}) -> {'error', string(), #state{}} | {'ok', pos_integer(), #state{}} | {'ok', #state{}}.
% handle_HELO(<<"invalid">>, State) ->
%     % contrived example
%     {error, "554 invalid hostname", State};
% handle_HELO(<<"trusted_host">>, State) ->
%     {ok, State};
handle_HELO(Hostname, State) ->
	error_logger:info_msg("SMTP: HELO from ~s~n", [Hostname]),
    {ok, 655360, State}. % 640kb of HELO should be enough for anyone.
%If {ok, State} was returned here, we'd use the default 10mb limit

-spec handle_EHLO(Hostname :: binary(), Extensions :: list(), State :: #state{}) -> {'error', string(), #state{}} | {'ok', list(), #state{}}.
% handle_EHLO(<<"invalid">>, _Extensions, State) ->
%     % contrived example
%     {error, "554 invalid hostname", State};
handle_EHLO(_Hostname, Extensions, State) ->
    MyExtensions = case proplists:get_value(auth, State#state.options, false) of
                       true ->
                           % auth is enabled, so advertise it
                           Extensions ++ [{"AUTH", "PLAIN LOGIN CRAM-MD5"}, {"STARTTLS", true}];
                       false ->
                           Extensions
                   end,
    {ok, MyExtensions, State}.

-spec handle_MAIL(From :: binary(), State :: #state{}) -> {'ok', #state{}} | {'error', string(), #state{}}.
handle_MAIL(_From, State) ->
    {ok, State}.

-spec handle_MAIL_extension(Extension :: binary(), State :: #state{}) -> {'ok', #state{}} | 'error'.
handle_MAIL_extension(_Extension, State) ->
    {ok, State}.

-spec handle_RCPT(To :: binary(), State :: #state{}) -> {'ok', #state{}} | {'error', string(), #state{}}.
handle_RCPT(_To, State) ->
	% Check if the "To" address exists
	% Check domain, check addressee in domain.
	% For bounces:
	% - To = <noreply+MSGID@example.org> 
	% - Return-Path header should be present and contains <>
    {ok, State}.

-spec handle_RCPT_extension(Extension :: binary(), State :: #state{}) -> {'ok', #state{}} | 'error'.
handle_RCPT_extension(_Extension, State) ->
    {ok, State}.

-spec handle_DATA(From :: binary(), To :: [binary(),...], Data :: binary(), State :: #state{}) -> {'ok', string(), #state{}} | {'error', string(), #state{}}.
handle_DATA(From, To, Data, State) ->
    Reference = lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X>> <= erlang:md5(term_to_binary({node(), erlang:now()}))]),
    try mimemail:decode(Data) of
        {Type, Subtype, Headers, Params, Body} ->
			case find_bounce_id(To, Headers) of
				{ok, MessageId} ->
					z_email_server:bounced(MessageId);
				ok ->
					% Bounced, but without a message id
					nop;
				no_bounce ->
					z_email_receive:received(To, From, Reference, {Type, Subtype}, Headers, Params, Body, Data)
			end
    catch
        What:Why ->
            error_logger:error_msg("SMTP receive: Message decode FAILED with ~p:~p", [What, Why])
    end,
    % At this point, if we return ok, we've accepted responsibility for the email
    {ok, Reference, State}.

-spec handle_RSET(State :: #state{}) -> #state{}.
handle_RSET(State) ->
    % reset any relevant internal state
    State.

-spec handle_VRFY(Address :: binary(), State :: #state{}) -> {'ok', string(), #state{}} | {'error', string(), #state{}}.
handle_VRFY(_Address, State) ->
    {error, "252 VRFY disabled by policy, just send some mail", State}.

-spec handle_other(Verb :: binary(), Args :: binary(), #state{}) -> {string(), #state{}}.
handle_other(Verb, _Args, State) ->
    % You can implement other SMTP verbs here, if you need to
    {lists:flatten(io_lib:format("500 Error: command not recognized : '~s'", [Verb])), State}.


-spec code_change(OldVsn :: any(), State :: #state{}, Extra :: any()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec terminate(Reason :: any(), State :: #state{}) -> {'ok', any(), #state{}}.
terminate(Reason, State) ->
    {ok, Reason, State}.


%% Internal functions

%% @doc A message is classified as a bounce when the recipient is <noreply+MSGID@example.org>
%% OR when the Return-Path is set to <>
find_bounce_id(Recipients, Headers) ->
	case find_bounce_email(Recipients) of
		{ok, _MessageId} = M -> 
			M;
		undefined ->
			case proplists:get_value(<<"Return-Path">>, Headers) of
				<<"<>">> -> ok;
				_ -> no_bounce
			end
	end.

% Check if one of the recipients is a bounce address
find_bounce_email([]) ->
	undefined;
find_bounce_email([To|Other]) ->
	case z_email_server:is_bounce_email(To) of
		true -> {ok, To};
		false -> find_bounce_email(Other)
	end.


	