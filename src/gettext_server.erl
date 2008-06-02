%%%-------------------------------------------------------------------
%%% File    : gettext_server.erl
%%% Author  : Torbjorn Tornkvist <tobbe@bluetail.com>
%%% Desc.   : Internationalization support.
%%% Created : 28 Oct 2003 by Torbjorn Tornkvist <tobbe@bluetail.com>
%%%-------------------------------------------------------------------
-module(gettext_server).

-behaviour(gen_server).
%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% External exports
-export([start/0, start_link/0, start/1, start_link/1, key2str/2,
	 store_pofile/2, all_lang/0, lang2cset/1, recreate_db/0,
	 reload_custom_lang/1, unload_custom_lang/1
         ,gettext_dir/0
         ,default_lang/0
        ]).

%% Default callback functions
-export([custom_dir/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
	 terminate/2, code_change/3]).

-include("gettext.hrl").

-define(elog(X,Y), error_logger:info_msg("*elog ~p:~p: " X,
					[?MODULE, ?LINE | Y])).

-define(SERVER, ?MODULE).
-define(TABLE_NAME, gettext_db).
-define(ETS_TABLE_NAME, gettext_db_ets).
-define(KEY(Lang,Key), {Key,Lang}).
-define(ENTRY(Lang, Key, Val), {?KEY(Lang,Key), Val}).


-record(state, {
	  cbmod = ?MODULE,   % callback module
	  cache = [],        % list_of( #cache{} )
	  gettext_dir,       % Dir where all the data are stored
          def_lang = ?DEFAULT_LANG
	 }).

%%%
%%% Hold info about the languages stored.
%%%
-record(cache, {
	  language  = ?DEFAULT_LANG,
	  charset   = ?DEFAULT_CHARSET
	 }).

%%====================================================================
%% External functions
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link/0
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    start_link(?MODULE).

start_link(CallBackMod) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, CallBackMod, []).

start() ->
    start(?MODULE).

start(CallBackMod) ->
    gen_server:start({local, ?SERVER}, ?MODULE, CallBackMod, []).

key2str(Key, Lang) ->
    try
        case ets:lookup(?ETS_TABLE_NAME, ?KEY(Lang, Key)) of
            []          -> Key;  
            [{_,Str}|_] -> Str
        end
    catch
        _:_ ->
            gen_server:call(?SERVER, {key2str, Key, Lang}, infinity)
    end.

lang2cset(Lang) ->
    gen_server:call(?SERVER, {lang2cset, Lang}, infinity).

store_pofile(Lang, File) when binary(File) ->
    gen_server:call(?SERVER, {store_pofile, Lang, File}, infinity).

reload_custom_lang(Lang) ->
    gen_server:call(?SERVER, {reload_custom_lang, Lang}, infinity).

unload_custom_lang(Lang) ->
    gen_server:call(?SERVER, {unload_custom_lang, Lang}, infinity).

recreate_db() ->
    gen_server:call(?SERVER, recreate_db, infinity).

gettext_dir() ->
    gen_server:call(?SERVER, gettext_dir, infinity).

default_lang() ->
    gen_server:call(?SERVER, default_lang, infinity).

all_lang() ->    
    L = dets:match(gettext_db, {{header_info, '$1'}, '_'}),
    [hd(X) || X <- L].

%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%--------------------------------------------------------------------
init(CallBackMod0) ->
    CallBackMod = get_callback_mod(CallBackMod0),
    GettextDir = get_gettext_dir(CallBackMod),
    DefLang = get_default_lang(CallBackMod),
    Cache = create_db(GettextDir),
    {ok, #state{cache       = Cache, 
		cbmod       = CallBackMod,
		gettext_dir = GettextDir,
                def_lang    = DefLang
               }}.

%%%
%%% The GETTEXT_CBMOD environment variable takes precedence!
%%%
get_callback_mod(CallBackMod0) ->
    case os:getenv("GETTEXT_CBMOD") of
	false -> CallBackMod0;
	CbMod -> list_to_atom(CbMod)
    end.

%%%
%%% The GETTEXT_DIR environment variable takes precedence!
%%% Next we will try to get hold of the value from the callback.
%%%
get_gettext_dir(CallBackMod) ->
    case os:getenv("GETTEXT_DIR") of
	false -> 
            if (CallBackMod /= ?MODULE) ->
                    case catch CallBackMod:gettext_dir() of
                        Dir when list(Dir) -> Dir;
                        _                  -> code:priv_dir(gettext) % fallback
                    end;
               true -> 
                    code:priv_dir(gettext) % fallback
            end;
	Dir -> Dir
    end.

%%%
%%% The GETTEXT_DIR environment variable takes precedence!
%%% Next we will try to get hold of the value from the callback.
%%%
get_default_lang(CallBackMod) ->
    case os:getenv("GETTEXT_DEF_LANG") of
	false -> 
            if (CallBackMod /= ?MODULE) ->
                    case catch CallBackMod:gettext_def_lang() of
                        Dir when list(Dir) -> Dir;
                        _                  -> ?DEFAULT_LANG % fallback
                    end;
               true ->
                    ?DEFAULT_LANG % fallback
            end;
	DefLang -> DefLang
    end.

%% Default callback function
custom_dir() ->
    code:priv_dir(gettext).


%%--------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call({key2str, Key, Lang}, _From, State) ->
    Reply = lookup(Lang, Key),
    {reply, Reply, State};
%%
handle_call({lang2cset, Lang}, _From, State) ->
    Reply = case lists:keysearch(Lang, #cache.language, State#state.cache) of
		false      -> {error, "not found"};
		{value, C} -> {ok, C#cache.charset}
	    end,
    {reply, Reply, State};
%%
handle_call({store_pofile, Lang, File}, _From, State) ->
    GettextDir = State#state.gettext_dir,
    case do_store_pofile(Lang, File, GettextDir, State#state.cache) of
	{ok, NewCache} ->
	    {reply, ok, State#state{cache = NewCache}};
	Else ->
	    {reply, Else, State}
    end;
%%
handle_call({reload_custom_lang, Lang}, _From, State) ->
    GettextDir = State#state.gettext_dir,
    case do_reload_custom_lang(GettextDir, Lang) of
	ok   -> {reply, ok, State};
	Else -> {reply, Else, State}
    end;
%%
handle_call({unload_custom_lang, Lang}, _From, State) ->
    GettextDir = State#state.gettext_dir,
    {reply, do_unload_custom_lang(GettextDir, Lang), State};
%%
handle_call(recreate_db, _From, State) ->
    GettextDir = State#state.gettext_dir,
    Fname = filename:join(GettextDir, "gettext_db.dets"),
    dets:close(?TABLE_NAME),
    file:delete(Fname),
    create_db(GettextDir, Fname),
    {reply, ok, State};
%%
handle_call(gettext_dir, _From, State) ->
    {reply, State#state.gettext_dir, State};
%%
handle_call(default_lang, _From, State) ->
    {reply, State#state.def_lang, State}.

	    

%%--------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

create_db(GettextDir) ->
    Fname = filename:join(GettextDir, "gettext_db.dets"),
    create_db(GettextDir, Fname).

create_db(GettextDir, Fname) ->
    filelib:ensure_dir(Fname), 
    init_db_table(GettextDir, Fname).


do_unload_custom_lang(GettextDir, Lang) ->
    Fname = filename:join([GettextDir, "lang", "custom", Lang, "gettext.po"]),
    case filelib:is_file(Fname) of
	true ->
	    dets:match_delete(gettext_db, {{'_',Lang},'_'}),
            recreate_ets_table(),
	    ok;
	false ->
	    {error, "no lang"}
    end.

do_reload_custom_lang(GettextDir, Lang) ->
    dets:match_delete(gettext_db, {{'_',Lang},'_'}),
    Dir = filename:join([GettextDir, "lang", "custom", Lang]),
    Fname = filename:join([Dir, "gettext.po"]), 
    insert_po_file(Lang, Fname),
    recreate_ets_table(),
    ok.

do_store_pofile(Lang, File, GettextDir, Cache) ->
    Dir = filename:join([GettextDir, "lang", "custom", Lang]),
    Fname = filename:join([Dir, "gettext.po"]), 
    filelib:ensure_dir(Fname), 
    case file:write_file(Fname, File) of
	ok ->
	    case lists:keymember(Lang, #cache.language, Cache) of
		true  -> delete_lc(Lang);
		false -> false
	    end,
	    insert_po_file(Lang, Fname),
	    {ok, [set_charset(#cache{language = Lang}) | Cache]};
	_ ->
	    {error, "failed to write PO file to disk"}
    end.

set_charset(C) ->
    case lookup(C#cache.language, ?GETTEXT_HEADER_INFO) of
	?GETTEXT_HEADER_INFO ->                   % nothing found...
	    C#cache{charset = ?DEFAULT_CHARSET};  % fallback
	Pfinfo ->
	    CharSet = get_charset(Pfinfo),
	    C#cache{charset = CharSet}
    end.


get_charset(Pfinfo) ->
    g_charset(string:tokens(Pfinfo,[$\n])).

g_charset(["Content-Type:" ++ Rest|_]) -> g_cset(Rest);
g_charset([_H|T])                      -> g_charset(T);
g_charset([])                          -> ?DEFAULT_CHARSET.

g_cset("charset=" ++ Charset) -> rm_trailing_stuff(Charset);
g_cset([_|T])                 -> g_cset(T);
g_cset([])                    -> ?DEFAULT_CHARSET.

rm_trailing_stuff(Charset) ->
    lists:reverse(eat_dust(lists:reverse(Charset))).

eat_dust([$\s|T]) -> eat_dust(T);
eat_dust([$\n|T]) -> eat_dust(T);
eat_dust([$\r|T]) -> eat_dust(T);
eat_dust([$\t|T]) -> eat_dust(T);
eat_dust(T)       -> T.


init_db_table(GettextDir, TableFile) ->
    case filelib:is_regular(TableFile) of
	false ->
	    create_and_populate(GettextDir, TableFile);
	true ->
	    %% If the dets file is broken, dets may not be able to repair it 
	    %% itself (it may be only half-written). So check and recreate 
	    %% if needed instead.
	    case open_dets_file(?TABLE_NAME, TableFile) of
		ok -> create_cache();
		_  -> create_and_populate(GettextDir, TableFile)
	    end
    end.

create_cache() ->
    F = fun(LC, Acc) ->
		case lookup(LC, ?GETTEXT_HEADER_INFO) of
		    ?GETTEXT_HEADER_INFO ->
			%% nothing found...
			?elog("Could not find header info for lang: ~s~n",[LC]),
			Acc;
		    Pfinfo ->
			CS = get_charset(Pfinfo),
			[#cache{language = LC, charset = CS}|Acc]
		end
	end,
    recreate_ets_table(),
    lists:foldl(F, [], all_lang()).
    


create_and_populate(GettextDir, TableFile) ->
    ?elog("TableFile = ~p~n", [TableFile]),
    %% Need to create and populate the DB.
    {ok, _} = dets:open_file(?TABLE_NAME,
			     [{file, TableFile},
			      %% creating on disk, esp w auto_save,
			      %% takes "forever" on flash disk
			      {ram_file, true}]), 
    L = populate_db(GettextDir),
    dets:close(?TABLE_NAME),    % flush to disk
    {ok, _} = dets:open_file(?TABLE_NAME, [{file, TableFile}]),
    recreate_ets_table(),
    L.

recreate_ets_table() ->
    try ets:delete(?ETS_TABLE_NAME) 
    catch _:_ -> true
    after
        create_and_populate_ets_table()
    end.

%% To speed up the read access 10-100 times !!
create_and_populate_ets_table() ->
    try 
        ets:new(?ETS_TABLE_NAME, [set, named_table, protected]),
        ets:from_dets(?ETS_TABLE_NAME, ?TABLE_NAME),
        true
    catch 
            _:_ -> false
    end.
            
        

open_dets_file(Tname, Fname) ->
    Opts = [{file, Fname}, {repair, false}],
    case dets:open_file(Tname, Opts) of
	{ok, _} ->
	    ok;
	_ ->
	    file:delete(Fname),
	    error
    end.

%%%
%%% Insert the given languages into the DB.
%%%
%%% NB: It is important to insert the 'predefiend' language
%%%     definitions first since a custom language should be
%%%     able to 'shadow' the the same predefined language.
%%%
populate_db(GettextDir) ->
    L = insert_predefined(GettextDir, []), 
    insert_custom(GettextDir, L).

insert_predefined(GettextDir, L) ->
    Dir = filename:join([GettextDir, "lang", "default"]),
    insert_data(Dir, L).

insert_data(Dir, L) ->
    case file:list_dir(Dir) of
	{ok, Dirs} ->
	    F = fun([$.|_], Acc)     -> Acc;  % ignore in a local inst. env.
		   ("CVS" ++ _, Acc) -> Acc;  % ignore in a local inst. env.
		   (LC, Acc)         ->
			Fname = filename:join([Dir, LC, "gettext.po"]),
			insert_po_file(LC, Fname),
			[#cache{language = LC} | Acc]
		end,
	    lists:foldl(F, L, Dirs);
	_ ->
	    L
    end.

insert_po_file(LC, Fname) ->
    case file:read_file_info(Fname) of
	{ok, _} ->
	    insert(LC, gettext:parse_po(Fname));
	_ ->
	    ?elog("gettext_server: Could not read ~s~n", [Fname]),
	    {error, "could not read PO file"}
    end.

insert_custom(GettextDir, L) ->
    Dir = filename:join([GettextDir, "lang", "custom"]),
    insert_data(Dir, L).

insert(LC, L) ->
    F = fun({Key, Val}) ->
		dets:insert(?TABLE_NAME, ?ENTRY(LC, Key, Val))
	end,
    lists:foreach(F, L).

lookup(Lang, Key) ->
    case dets:lookup(?TABLE_NAME, ?KEY(Lang, Key)) of
	[]          -> Key;  
	[{_,Str}|_] -> Str
    end.
    

delete_lc(LC) ->
    dets:match_delete(?TABLE_NAME, ?ENTRY(LC, '_', '_')).
    
