# Fair warning

This extension was built with a lot of help from AI. I've gone through and checked all of it, but I didn't change all the wording and such, and it is possible I've missed something.

Tools are cool, and we should use them.

# Quarto-microdata Extension For Quarto

Add Schema.org semantics (or any other semantics you want) to your Quarto sites with a friendly, Markdown-first DSL. This extension turns compact bracket syntax into **Microdata** and **RDFa** (by default it emits both) and also **injects JSON-LD** into the page `<head>` so search engines can read your structured data.

## Installing

Replace the `<github-organization>` with your GitHub org or username:

```bash
quarto add <github-organization>/quarto-microdata
```

This installs the extension under `_extensions/`. If you use version control, commit that directory.

## Using

1. **Enable the filter**

In your project `_quarto.yml` (or a single document’s YAML), add:

```yaml
filters:
  - quarto-microdata
```

2. **(Optional) Configure defaults**

```yaml
schema-brackets:
  syntax: both              # microdata | rdfa | both (default: both)
  jsonld: true              # inject JSON-LD <script> (default: true)
  vocab: "https://schema.org/"   # default base IRI for types
  prefixes:                 # optional CURIE prefixes for multi-vocab docs
    schema: "https://schema.org/"
    dc:     "http://purl.org/dc/terms/"
  context:                  # JSON-LD @context (string, list, or map)
    "@vocab": "https://schema.org/"
    dc: "http://purl.org/dc/terms/"
```

3. **Write semantics with the DSL**

* **Item (inline or block)**
  `<<item:TYPE>>[ ... ]`
  If the opener is alone on a line, it wraps **multiple blocks** until a lone `]` line.

* **Property (inline)**
  `<<prop:NAME>>[ ... ]` **or** `<<NAME>>[ ... ]` (shorthand)

* **Per-item vocab** (optional)
  `<<item:dc:CreativeWork vocab=http://purl.org/dc/terms/>>[ ... ]`

* **Links & images**
  For URL-valued props (e.g., `trailer`, `url`, `sameAs`, `image`), wrap the link or image:

  ```
  <<trailer>>[[Watch trailer](../movies/avatar-trailer.html)]
  ```

  The filter hoists the property onto the `<a>`/`<img>` so the **href/src** becomes the value.

### Minimal example (inline)

```markdown
<<item:Movie>>[
# <<name>>[Avatar]

**Director:** <<item:Person prop=director>>[
  <<name>>[James Cameron] (born <<birthDate>>[1954-08-16])
]

**Genre:** <<genre>>[Science fiction]  
<<trailer>>[[Trailer](../movies/avatar-theatrical-trailer.html)]
]
```

**What you’ll get (abridged):**

* Microdata (`itemscope`, `itemtype`) **and** RDFa (`vocab`, `typeof`, `property`) on the same nodes
* JSON-LD injected into `<head>`:

  ```json
  {
    "@context": "https://schema.org",
    "@graph": [{
      "@type": "Movie",
      "name": "Avatar",
      "director": { "@type": "Person", "name": "James Cameron", "birthDate": "1954-08-16" },
      "genre": "Science fiction",
      "trailer": "../movies/avatar-theatrical-trailer.html"
    }]
  }
  ```

### Tips

* Use ISO dates (`YYYY-MM-DD`) inside date properties (`<<birthDate>>[1954-08-16]`) so the filter can emit `<time datetime="…">`.
* You can mix vocabularies by setting `vocab=…` per item and defining `prefixes:` in YAML; JSON-LD will compact types using those prefixes when possible.
* Set `schema-brackets.syntax: microdata` or `rdfa` if you only want one syntax.

## Example

Here is the source code for a minimal example: [example.qmd](example.qmd)


