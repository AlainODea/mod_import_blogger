{% if m.acl.use.mod_import_blogger %}
<h2>{_ Blogger import _}</h2>
<div class="clearfix">
    {% button class="" text=_"Blogger import" action={dialog_open title=_"Import XML file" template="_dialog_import_blogger.tpl"} %} 
    <span class="expl">{_ Import a Blogger GData XML export file into Zotonic. _}</span>
</div>
{% endif %}
