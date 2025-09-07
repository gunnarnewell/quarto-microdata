-- Schema.org double-angle-bracket syntax filter for Quarto/Pandoc
-- Features:
--   • Author with:  <<item:TYPE>>[ ... ], <<prop:NAME>>[ ... ], <<NAME>>[ ... ]
--   • Outputs Microdata + RDFa by default (configurable)
--   • Auto JSON-LD (@graph) injected into <head>
--   • NEW: per-item vocab (base IRI) and multi-vocab support via YAML prefixes
--   • NEW: configurable JSON-LD @context (string, list, or map)
--
-- YAML config (site-wide in _quarto.yml or per-page):
-- schema-brackets:
--   syntax: both        # 'microdata' | 'rdfa' | 'both'  (default: both)
--   jsonld: true        # auto JSON-LD (default: true)
--   vocab: "https://schema.org/"       # default base IRI for item types
--   prefixes:                        # (optional) CURIE prefixes for multi-vocab
--     schema: "https://schema.org/"
--     dc:     "http://purl.org/dc/terms/"
--   context:                        # JSON-LD @context; string | list | map
--     "@vocab": "https://schema.org/"
--     dc: "http://purl.org/dc/terms/"
--
-- Example authoring:
-- <<item:Movie>>[
-- # <<name>>[Avatar]
-- **Director:** <<item:Person prop=director>>[<<name>>[James Cameron] (born <<birthDate>>[1954-08-16])]
-- **Genre:** <<genre>>[Science fiction]
-- <<trailer>>[[**Trailer**](../movies/avatar-theatrical-trailer.html)]
-- ]
--
-- Mix vocabularies per item:
-- <<item:dc:CreativeWork vocab=http://purl.org/dc/terms/>>[
--   <<dc:title>>[Avatar Review]
-- ]

-- ========================= Config defaults =========================
local VOCAB  = "https://schema.org/"
local MODE   = "both"        -- microdata | rdfa | both
local JSONLD = true
local JSONLD_CONTEXT = "https://schema.org"
local PREFIXES = {}           -- e.g., { schema = "https://schema.org/", dc = "http://purl.org/dc/terms/" }

-- ========================= Small helpers =========================
local function trim(s) return (s:gsub("^%s+","")):gsub("%s+$","") end

-- join base IRI and term safely (handles trailing '/' or '#')
local function join_iri(base, term)
  if not base or base == "" then return term end
  local last = base:sub(-1)
  if last == "/" or last == "#" then return base .. term end
  return base .. "/" .. term
end

-- resolve a TYPE token into an absolute IRI for Microdata itemtype
-- supports absolute IRI, CURIE (prefix:Term), or bare Term using a base vocab
local function resolve_type_iri(typ, base)
  if not typ then return nil end
  if typ:match("^%a[%w+.-]*://") then
    return typ -- already absolute IRI
  end
  local pfx, rest = typ:match("^([^:]+):(.+)$")
  if pfx and rest and PREFIXES[pfx] then
    return join_iri(PREFIXES[pfx], rest)
  end
  return join_iri(base or VOCAB, typ)
end

-- convert PREFIXES table into RDFa prefix attribute string
local function prefixes_attr()
  local parts = {}
  for k, v in pairs(PREFIXES) do parts[#parts+1] = string.format("%s: %s", k, v) end
  table.sort(parts) -- stable order
  return table.concat(parts, " ")
end

-- parse k=v attributes after TYPE, e.g., " prop=director vocab=..."
local function parse_kv(tail)
  local kv = {}
  for k, v in tail:gmatch("([%w_%-]+)%s*=%s*([%w%._:#/%%-]+)") do kv[k] = v end
  return kv
end

-- Opening tokens (support WITH or WITHOUT the following '[')
--   <<item:TYPE ...>>[    or   <<item:TYPE ...>>
--   <<prop:NAME>>[        or   <<prop:NAME>>
--   <<NAME>>[             or   <<NAME>>
local function parse_opening_token(text)
  local s = trim(text)
  s = s:gsub(">>%s+%[", ">>[") -- normalize any space before '['

  -- item
  do
    local typ, tail = s:match("^<<%s*item%s*:%s*([%w%._:%-]+)(.-)>>%s*%[%s*$")
    if typ then return { kind="item", type=typ, attrs=parse_kv(tail or ""), needs_next_bracket=false } end
    local typ2, tail2 = s:match("^<<%s*item%s*:%s*([%w%._:%-]+)(.-)>>%s*$")
    if typ2 then return { kind="item", type=typ2, attrs=parse_kv(tail2 or ""), needs_next_bracket=true } end
  end
  -- explicit prop
  do
    local name = s:match("^<<%s*prop%s*:%s*([%w%._:%-]+)%s*>>%s*%[%s*$")
    if name then return { kind="prop", name=name, needs_next_bracket=false } end
    local name2 = s:match("^<<%s*prop%s*:%s*([%w%._:%-]+)%s*>>%s*$")
    if name2 then return { kind="prop", name=name2, needs_next_bracket=true } end
  end
  -- shorthand prop
  do
    local name = s:match("^<<%s*([%w%._:%-]+)%s*>>%s*%[%s*$")
    if name and name ~= "item" and name ~= "prop" then
      return { kind="prop", name=name, short=true, needs_next_bracket=false }
    end
    local name2 = s:match("^<<%s*([%w%._:%-]+)%s*>>%s*$")
    if name2 and name2 ~= "item" and name2 ~= "prop" then
      return { kind="prop", name=name2, short=true, needs_next_bracket=true }
    end
  end
  return nil
end

-- Recognize a close token ']' either as a whole Str or embedded in a Str.
local function close_bracket_info(el)
  if el.t ~= "Str" then return nil end
  local t = el.text
  local idx = t:find("%]")
  if not idx then return nil end
  -- return pieces: before ']' and after ']'
  return { before = t:sub(1, idx-1), after = t:sub(idx+1) }
end

-- If an opener was seen *without* '[', consume a leading '[' from the next Str
local function consume_leading_bracket(inlines, pos)
  local nxt = inlines[pos+1]
  if nxt and nxt.t == "Str" then
    local t = nxt.text
    if t:sub(1,1) == "[" then
      local rest = t:sub(2)
      if rest ~= "" then
        inlines[pos+1] = pandoc.Str(rest)
      else
        table.remove(inlines, pos+1)
      end
      return true
    end
  end
  return false
end

-- Build attrs for item container (Microdata/RDFa/both), honoring per-item vocab
local function item_attr(typ, maybeProp, attrs)
  local kv = {}
  local local_vocab = (attrs and attrs.vocab) or VOCAB
  if MODE == "microdata" or MODE == "both" then
    kv.itemscope = ""
    kv.itemtype  = resolve_type_iri(typ, local_vocab)
    if maybeProp and maybeProp ~= "" then kv.itemprop = maybeProp end
  end
  if MODE == "rdfa" or MODE == "both" then
    kv.vocab  = local_vocab
    kv.typeof = typ
    if next(PREFIXES) ~= nil then kv.prefix = prefixes_attr() end
    if maybeProp and maybeProp ~= "" then kv.property = maybeProp end
  end
  return pandoc.Attr("", {}, kv)
end

-- Build attrs for a property span (supports CURIE names for RDFa)
local function prop_attr(name)
  local kv = {}
  if MODE == "microdata" or MODE == "both" then kv.itemprop = name end
  if MODE == "rdfa" or MODE == "both" then kv.property = name end
  return pandoc.Attr("", {}, kv)
end

-- Recursively process inline sequences, rewriting <<...>>[ ... ] into spans
local function process_inlines(inlines, i0)
  local out, i = {}, i0 or 1
  while i <= #inlines do
    local el = inlines[i]
    if el.t == "Str" then
      local open = parse_opening_token(el.text)
      if open then
        -- If the opener didn't include '[', the next token must supply it
        if open.needs_next_bracket and not consume_leading_bracket(inlines, i) then
          -- Not actually an opener; emit literally
          table.insert(out, el); i = i + 1
        else
          -- find matching close with nesting
          local depth, j = 1, i + 1
          local before_at_close, after_at_close = nil, nil
          while j <= #inlines do
            local e = inlines[j]
            if e.t == "Str" then
              local op2 = parse_opening_token(e.text)
              if op2 then
                -- if the nested opener requires '[', try to consume it
                if op2.needs_next_bracket then consume_leading_bracket(inlines, j) end
                depth = depth + 1
              else
                local cinfo = close_bracket_info(e)
                if cinfo then
                  depth = depth - 1
                  if depth == 0 then
                    before_at_close, after_at_close = cinfo.before, cinfo.after
                    break
                  end
                end
              end
            end
            j = j + 1
          end

          if j > #inlines then
            -- no close; treat literally
            table.insert(out, el); i = i + 1
          else
            -- build inner slice (i+1..j-1) plus possible 'before' from close token
            local inner = {}
            for k = i + 1, j - 1 do table.insert(inner, inlines[k]) end
            if before_at_close and before_at_close ~= "" then
              table.insert(inner, pandoc.Str(before_at_close))
            end
            inner = process_inlines(inner, 1)

            local replaced
            if open.kind == "prop" then
              -- HOIST: if exactly one Link/Image, put attributes on it
              if #inner == 1 and (inner[1].t == "Link" or inner[1].t == "Image") then
                local el1 = inner[1]
                local attrs = (el1.attr and el1.attr.attributes) or {}
                if MODE == "microdata" or MODE == "both" then attrs.itemprop = open.name end
                if MODE == "rdfa" or MODE == "both" then attrs.property = open.name end
                el1.attr = pandoc.Attr("", {}, attrs)
                replaced = el1
              else
                replaced = pandoc.Span(inner, prop_attr(open.name))
              end
            else
              replaced = pandoc.Span(inner, item_attr(open.type, open.attrs and open.attrs.prop, open.attrs))
            end

            -- emit replaced
            table.insert(out, replaced)

            -- put any trailing text (after ']') back into the stream
            if after_at_close and after_at_close ~= "" then
              table.insert(out, pandoc.Str(after_at_close))
            end

            -- advance i past consumed range
            i = j + 1
          end
        end
      else
        table.insert(out, el); i = i + 1
      end
    else
      if el.content then el.content = process_inlines(el.content, 1) end
      table.insert(out, el); i = i + 1
    end
  end
  return out
end

-- Map inline-bearing blocks through process_inlines
local function map_block_inlines(b)
  if b.t == "Para" or b.t == "Plain" or b.t == "Header" then
    b.content = process_inlines(b.content, 1); return b
  elseif b.t == "BlockQuote" then
    b.content = pandoc.walk_block(pandoc.BlockQuote(b.content), { Para = map_block_inlines, Plain = map_block_inlines, Header = map_block_inlines }).content; return b
  elseif b.t == "Div" then
    b.content = pandoc.walk_block(pandoc.Div(b.content, b.attr), { Para = map_block_inlines, Plain = map_block_inlines, Header = map_block_inlines }).content; return b
  elseif b.t == "BulletList" or b.t == "OrderedList" then
    for i, item in ipairs(b.content) do for j, blk in ipairs(item) do item[j] = map_block_inlines(blk) end end; return b
  elseif b.t == "Table" and b.bodies then
    local function walk_cells(cells)
      for r = 1, #cells do for c = 1, #cells[r] do cells[r][c] = pandoc.walk_block(cells[r][c], { Para = map_block_inlines, Plain = map_block_inlines, Header = map_block_inlines }) end end
    end
    for _, body in ipairs(b.bodies) do walk_cells(body.body) end; return b
  end
  return b
end

-- Block-level folding: a paragraph that is exactly <<item:TYPE>>[ starts a block scope
local function fold_block_items(blocks)
  local out, i = {}, 1
  while i <= #blocks do
    local b = blocks[i]
    local openInfo = nil
    if b.t == "Para" and #b.content == 1 and b.content[1].t == "Str" then
      local maybe = parse_opening_token(b.content[1].text)
      if maybe and maybe.kind == "item" then openInfo = maybe end
    end
    if not openInfo then
      table.insert(out, map_block_inlines(b)); i = i + 1
    else
      local inner, depth = {}, 1; i = i + 1
      while i <= #blocks do
        local bb = blocks[i]; local isOpen2, isClose2 = false, false
        if bb.t == "Para" and #bb.content == 1 and bb.content[1].t == "Str" then
          local mo = parse_opening_token(bb.content[1].text)
          if mo and mo.kind == "item" then isOpen2 = true end
          if is_close_token(bb.content[1]) then isClose2 = true end
        end
        if isOpen2 then depth = depth + 1; table.insert(inner, bb)
        elseif isClose2 then depth = depth - 1
          if depth == 0 then
            local wrapped = {}; for _, ib in ipairs(inner) do table.insert(wrapped, map_block_inlines(ib)) end
            local div = pandoc.Div(wrapped, item_attr(openInfo.type, openInfo.attrs and openInfo.attrs.prop, openInfo.attrs))
            table.insert(out, div); i = i + 1; goto continue
          else table.insert(inner, bb) end
        else table.insert(inner, bb) end
        i = i + 1
      end
      -- unmatched close: emit literal
      table.insert(out, map_block_inlines(b)); for _, ib in ipairs(inner) do table.insert(out, map_block_inlines(ib)) end
    end
    ::continue::
  end
  return out
end

-- ========================= JSON-LD helpers =========================
local function has_attr(el, key) return el and el.attr and el.attr.attributes and el.attr.attributes[key] ~= nil end
local function get_attr(el, key) return el and el.attr and el.attr.attributes and el.attr.attributes[key] or nil end
local function get_local_vocab(el) return get_attr(el, "vocab") or VOCAB end
local function get_prop_name(el) return get_attr(el, "itemprop") or get_attr(el, "property") end

-- prefer RDFa typeof; else derive from Microdata itemtype
local function type_for_jsonld(el)
  local t = get_attr(el, "typeof")
  if t and t ~= "" then return t end
  local it = get_attr(el, "itemtype")
  if not it or it == "" then return nil end
  -- try to compact with known prefixes
  for pfx, base in pairs(PREFIXES) do
    if it:sub(1, #base) == base then
      local term = it:match("[^/#]+$") or it
      return pfx .. ":" .. term
    end
  end
  -- else, try to strip current/local vocab
  local voc = get_local_vocab(el)
  if it:sub(1, #voc) == voc then
    local term = it:match("[^/#]+$") or it
    return term
  end
  return it -- absolute IRI as fallback
end

local function stringify_inlines(inlines) return pandoc.utils.stringify(pandoc.Inlines(inlines)) end

local function add_prop(obj, key, value)
  local existing = obj[key]
  if existing == nil then obj[key] = value
  elseif type(existing) == "table" and existing[1] ~= nil then table.insert(existing, value)
  else obj[key] = { existing, value } end
end

local function value_of_inline(el)
  if el.t == "Link" then return el.target
  elseif el.t == "Image" then return el.src
  elseif el.t == "Span" or el.t == "Strong" or el.t == "Emph" or el.t == "Code" or el.t == "SmallCaps" then
    return stringify_inlines(el.content or {})
  else return nil end
end

local function traverse_inlines_for_props(inlines, obj)
  local i = 1
  while i <= #inlines do
    local el = inlines[i]
    if el.t == "Span" then
      local isChildItem = (get_attr(el, "itemscope") ~= nil) or (get_attr(el, "typeof") ~= nil)
      local propName = get_prop_name(el)
      if isChildItem then
        local child = collect_item_from_span(el)
        if propName and child then add_prop(obj, propName, child) end
      elseif propName then
        local val = value_of_inline(el) or stringify_inlines(el.content or {})
        if val and val ~= "" then add_prop(obj, propName, val) end
      else
        if el.content then traverse_inlines_for_props(el.content, obj) end
      end
    elseif el.t == "Link" or el.t == "Image" then
      local propName = get_prop_name(el)
      if propName then local val = value_of_inline(el); if val then add_prop(obj, propName, val) end end
    elseif el.content then
      traverse_inlines_for_props(el.content, obj)
    end
    i = i + 1
  end
end

local function traverse_blocks_for_props(blocks, obj)
  for _, b in ipairs(blocks) do
    if b.t == "Para" or b.t == "Plain" or b.t == "Header" then
      traverse_inlines_for_props(b.content, obj)
    elseif b.t == "Div" then
      if (get_attr(b, "itemscope") or get_attr(b, "typeof")) then
        local prop = get_prop_name(b)
        local child = collect_item_from_div(b)
        if prop and child then add_prop(obj, prop, child) end
      else
        traverse_blocks_for_props(b.content, obj)
      end
    elseif b.t == "BulletList" or b.t == "OrderedList" then
      for _, item in ipairs(b.content) do for _, blk in ipairs(item) do traverse_blocks_for_props({blk}, obj) end end
    elseif b.t == "Table" and b.bodies then
      for _, body in ipairs(b.bodies) do for _, row in ipairs(body.body) do for _, cell in ipairs(row) do traverse_blocks_for_props(cell, obj) end end end
    end
  end
end

function collect_item_from_div(div)
  local t = type_for_jsonld(div); if not t then return nil end
  local obj = { ["@type"] = t }
  traverse_blocks_for_props(div.content or {}, obj)
  return obj
end

function collect_item_from_span(span)
  local t = type_for_jsonld(span); if not t then return nil end
  local obj = { ["@type"] = t }
  traverse_inlines_for_props(span.content or {}, obj)
  return obj
end

local function find_top_level_items(blocks)
  local nodes = {}
  for _, b in ipairs(blocks) do
    if b.t == "Div" and (get_attr(b,"itemscope") or get_attr(b,"typeof")) and (get_prop_name(b) == nil) then
      local obj = collect_item_from_div(b); if obj then table.insert(nodes, obj) end
    elseif b.t == "Para" or b.t == "Plain" or b.t == "Header" then
      for _, inl in ipairs(b.content) do
        if inl.t == "Span" and (get_attr(inl,"itemscope") or get_attr(inl,"typeof")) and (get_prop_name(inl) == nil) then
          local obj = collect_item_from_span(inl); if obj then table.insert(nodes, obj) end
        end
      end
    elseif b.t == "Div" then
      local sub = find_top_level_items(b.content); for _, n in ipairs(sub) do table.insert(nodes, n) end
    end
  end
  return nodes
end

-- ===== JSON encode (safe, minimal) =====
local function json_escape(s)
  -- only escape the essentials to avoid parser quirks
  s = s:gsub("\\", "\\\\")
       :gsub('"', '\\"')
       :gsub("\r", "\\r")
       :gsub("\n", "\\n")
       :gsub("\t", "\\t")
  return s
end

local function is_array(tbl)
  local n = 0
  for k,_ in pairs(tbl) do
    if type(k) ~= "number" then return false end
    if k > n then n = k end
  end
  for i = 1, n do if tbl[i] == nil then return false end end
  return n > 0
end

local function to_json(v)
  local tv = type(v)
  if tv == "nil" then
    return "null"
  elseif tv == "boolean" then
    return v and "true" or "false"
  elseif tv == "number" then
    return tostring(v)
  elseif tv == "string" then
    return '"' .. json_escape(v) .. '"'
  elseif tv == "table" then
    if is_array(v) then
      local parts = {}
      for i = 1, #v do parts[#parts+1] = to_json(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts+1] = '"' .. json_escape(k) .. '":' .. to_json(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    return '""'
  end
end

local function inject_jsonld(doc, graph)
  if not graph or #graph == 0 then return doc end
  local payload = { ["@context"] = merge_context_and_prefixes(), ["@graph"] = graph }
  local json = to_json(payload)
  local html = '<script type="application/ld+json">' .. json .. '</script>'
  local block = pandoc.RawBlock('html', html)

  local hi = doc.meta["header-includes"]
  if hi == nil then
    doc.meta["header-includes"] = pandoc.MetaList({ block })
  else
    if hi.t ~= "MetaList" then
      doc.meta["header-includes"] = pandoc.MetaList({ hi, block })
    else
      local lst = hi
      table.insert(lst, block)
      doc.meta["header-includes"] = lst
    end
  end
  return doc
end

-- ========================= Meta & main entry =========================
function Meta(meta)
  local cfg = meta["schema-brackets"]
  if cfg then
    if cfg["syntax"]    then MODE = pandoc.utils.stringify(cfg["syntax"]) end
    if cfg["jsonld"]~=nil then JSONLD = pandoc.utils.stringify(cfg["jsonld"]) ~= "false" end
    if cfg["vocab"]     then
      VOCAB = pandoc.utils.stringify(cfg["vocab"]) or VOCAB
      local last = VOCAB:sub(-1); if last ~= "/" and last ~= "#" then VOCAB = VOCAB .. "/" end
    end
    if cfg["context"]   then
      local c = cfg["context"]
      if type(c) == "table" and c.t == "MetaList" then
        local arr = {}; for i, v in ipairs(c) do arr[i] = pandoc.utils.stringify(v) end
        JSONLD_CONTEXT = arr
      elseif type(c) == "table" and c.t == "MetaMap" then
        local map = {}
        for k, v in pairs(c) do map[k] = pandoc.utils.stringify(v) end
        JSONLD_CONTEXT = map
      else
        JSONLD_CONTEXT = pandoc.utils.stringify(c)
      end
    end
    if cfg["prefixes"] then
      if type(cfg["prefixes"]) == "table" then
        -- MetaMap or MetaList of pairs is possible; handle MetaMap
        if cfg["prefixes"].t == "MetaMap" then
          for k,v in pairs(cfg["prefixes"]) do PREFIXES[k] = pandoc.utils.stringify(v) end
        else
          -- generic Lua table (already plain), copy
          for k,v in pairs(cfg["prefixes"]) do PREFIXES[k] = pandoc.utils.stringify(v) end
        end
      end
    end
  end
  return meta
end

function Pandoc(doc)
  -- transform bracket DSL into Microdata/RDFa attributes (with per-item vocab)
  doc.blocks = fold_block_items(doc.blocks)
  -- auto JSON-LD
  if JSONLD then
    local nodes = find_top_level_items(doc.blocks)
    doc = inject_jsonld(doc, nodes)
  end
  return doc
end
