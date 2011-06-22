%% @author Alain O'Dea <alain.odea@gmail.com>
%% @copyright 2010 Alain O'Dea
%% @date 2011-06-19
%% @doc Import/export for zotonic.

%% Copyright 2010,2011 Alain O'Dea
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(mod_import_blogger).
-author("Alain O'Dea <alain.odea@gmail.com>").

-mod_title("Blogger import").
-mod_description("Import Blogger.com blog from GData XML file.").

-include_lib("xmerl/include/xmerl.hrl").
-include("zotonic.hrl").

-define(GDATA_KIND, "http://schemas.google.com/g/2005#kind").
-define(GDATA_COMMENT, "http://schemas.google.com/blogger/2008/kind#comment").
-define(GDATA_POST, "http://schemas.google.com/blogger/2008/kind#post").
-define(GDATA_TEMPLATE, "http://schemas.google.com/blogger/2008/kind#template").

%% interface functions
-export([event/2, import/3, blogger_datamodel/1]).

event({submit, {blogger_upload, []}, _TriggerId, _TargetId}, Context) ->
    #upload{filename=OriginalFilename, tmpfile=TmpFile} = z_context:get_q_validated("upload_file", Context),
    Reset = z_convert:to_bool(z_context:get_q("reset", Context)),
    spawn(fun() ->
		  ok = import(TmpFile, Reset, Context),
		  Msg = lists:flatten(io_lib:format("The import of ~p has completed.", [OriginalFilename])),
		  z_session_manager:broadcast(#broadcast{type="notice", message=Msg, title="Blogger import", stay=false}, Context)
	end),
    Context2 = z_render:growl("Please hold on while the file is importing. You will get a notification when it is ready.", Context),
    z_render:wire([{dialog_close, []}], Context2).

%% @doc Import a GData .xml blogger file. The reset flag controls whether or not previously deleted resources will be recreated.
import(Filename, Reset, Context) ->
    reset(Reset, Context),
    z_datamodel:manage(?MODULE, blogger_datamodel(Filename), Context).

reset(true, Context) -> z_datamodel:reset_deleted(?MODULE, Context);
reset(_, _) -> ok.

blogger_datamodel(Filename) -> articles(xmerl_scan:file(Filename)).

articles({Feed, _}) ->
    articles(xmerl_xpath:string("/feed/entry", Feed), #datamodel{
        categories = [
            {blogger_article, article, [
                {title, "Blogger Article"},
    			{summary, "Article imported from Blogger.com."}
            ]},
            {blogger_text, text, [
                {title, "Blogger Text"},
    			{summary, "Text imported from Blogger.com."}
            ]},
            {blogger_template, text, [
                {title, "Blogger Template"},
    			{summary, "Template imported from Blogger.com."}
            ]}
        ]
    }).
articles([], Data) -> Data;
articles([Entry|Nodes], Data) -> articles(Nodes, article(Entry, Data)).

article(Entry, Data) -> article(category(Entry), Entry, Data).
% TODO: handle comments properly (m_comment has its own table)
article(blogger_comment, _, Data) -> Data;
% TODO: somehow serialize templates so they don't choke Zotonic's importer
article(blogger_template, _, Data) -> Data;
article(Category, Entry, Data = #datamodel{resources = Resources}) ->
    keywords(Entry, Data#datamodel{
        resources = [article_resource(Category, Entry)| Resources]
    }).

article_resource(Category, Entry) ->
    {unique_name(Entry), Category, [
        {title, title(Entry)},
        {publication_start, publication_start(Entry)},
        {body, body(Entry)}
     ]
    }.

%% tag:blogger.com,1999:blog-1172307519118716047.post-7662808638216931426
%% Reverse entire ID and search backwards for first dash
unique_name(Entry) ->
    unique_name_parse(xmerl_xpath:string("id/text()", Entry)).
unique_name_parse([#xmlText{value=EntryId}]) ->
    unique_name_parse(lists:reverse(EntryId), []).
unique_name_parse([$-|_], PostId) -> "blogger_" ++  PostId;
unique_name_parse([Char|Rest], Acc) ->
    unique_name_parse(Rest, [Char|Acc]).

category(Entry) -> find_category(xmerl_xpath:string("category", Entry)).

find_category([]) -> blogger_text;
find_category([Category|Nodes]) ->
    case xmerl_xpath:string("@scheme", Category) of
    [#xmlAttribute{value=?GDATA_KIND}] ->
        case xmerl_xpath:string("@term", Category) of
        [#xmlAttribute{value=?GDATA_COMMENT}] -> blogger_comment;
        [#xmlAttribute{value=?GDATA_POST}] -> blogger_article;
        [#xmlAttribute{value=?GDATA_TEMPLATE}] -> blogger_template;
        _ -> blogger_text
        end;
    _ -> find_category(Nodes)
    end.

title(Entry) ->
    inner_text(xmerl_xpath:string("title/text()", Entry)).

publication_start(Entry) ->
    [#xmlText{value=Published}] = xmerl_xpath:string("published/text()", Entry),
    z_convert:to_datetime(Published).

body(Entry) -> inner_text(xmerl_xpath:string("content/text()", Entry), []).

inner_text(Nodes) -> inner_text(Nodes, []).
inner_text([], Body) -> lists:reverse(Body);
inner_text([#xmlText{value=Text}|Nodes], Acc) ->
    inner_text(Nodes, [use_entities(Text)|Acc]).

use_entities(Chars) -> use_entities(Chars, []).
use_entities([], Acc) -> lists:reverse(Acc);
use_entities([Char|Chars], Acc) when Char < 32 ; Char > 127 ->
    use_entities(Chars, [io_lib:format("&#~w;", [Char])|Acc]);
use_entities([Char|Chars], Acc) ->
    use_entities(Chars, [Char|Acc]).

keywords(Entry, Data = #datamodel{resources = [{UniqueName, _, _}|_]}) ->
    keywords(UniqueName, xmerl_xpath:string("category/@term", Entry), Data).
keywords(_, [], Data) -> Data;
keywords(UniqueName, [#xmlAttribute{value=Keyword}|Attributes], Data) ->
    keywords(UniqueName, Attributes, keyword(UniqueName, Keyword, Data)).

keyword(_, "http://" ++ _, Data) -> Data;
keyword(UniqueName, Keyword, Data = #datamodel{
        resources=Resources, edges=Edges}) ->
    KWUniqueName = kw_unique_name(Keyword),
    Data#datamodel{
        resources = [kw_resource(KWUniqueName, Keyword)|Resources],
        edges = [kw_edge(UniqueName, KWUniqueName)|Edges]
    }.

kw_unique_name(Keyword) ->
    list_to_atom("kw_" ++ string:to_lower(Keyword)).

kw_resource(KWUniqueName, Keyword) ->
    {KWUniqueName,
     keyword,
     [{title, Keyword}]
    }.

kw_edge(UniqueName, KWUniqueName) -> {UniqueName, subject, KWUniqueName}.

