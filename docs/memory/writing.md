---
name: writing
description: Writing rules for every text in prismarine that a person reads, from comments to commit messages
type: feedback
---

# Writing rules

These rules cover every text in the repository that a person reads. They apply while the text is written, not as a
later cleanup pass.

## Scope

The rules apply to these texts.

- Doc comments and inline comments, in Dart, Rust, GLSL, Python and shell.
- Descriptions of settings and options, in debug panel options, environment variables and the help of a command line.
- Error messages, log lines and the output of scripts and tools.
- `README.md`, `CLAUDE.md` and the pages under `docs/`.
- Titles, labels and legends of figures and debug views, such as a frame graph.
- Commit messages.

Readers are engineers who build games. Many of them are not native English speakers.

## Wording

Use simple, plain engineering English. A sentence has a plain subject, a verb and an object. Start with the thing or
with a verb, as in "Fails unless the plan has a target" or "The pool that holds the vertex data".

Do not open with What, Where, How, Who, Whether, When, Which or Why. This applies to sentences, headings,
descriptions and parameter texts.

Do not invert a sentence and leave a preposition at its end. "The buffer the runner reads the draws from" is wrong.
Write "the buffer that holds the draws". Do not use clever constructions or a fronted fragment as a sentence.

Do not use metaphors or euphemisms. These words are banned.

- "sits", "lives", "lands". Say "is in" or "is located in".
- "hears", "tells", "told", "hands out", "hands on". Say "receives", "gets", "publishes" or "replies with".
- "rides", "climbs out".
- "name", "names", "named" and "naming" as a verb.
- "write" and "written" for the look of a value. Say "has the form". "Write" is for writing data.

Do not use a ", so" consequence clause, a "because" clause, "so that" or "unlike X" to justify a design. The reason
belongs in the commit message. A clause of this kind stays only when it carries a constraint the next editor would
break, as in "the GPU reads this buffer in place, so the caller must not resize it".

Do not put a comma before "and". Join the two parts without it. Write two sentences where the joined one reads badly.

Do not use capitals for emphasis. A word in capitals is an acronym or an identifier, not a stressed "not", "is" or
"all". Use backticks only for the identifiers that need them. Use few parentheses. An aside becomes its own sentence
or is dropped.

Do not write a compressed riddle. "A retained pass stays cold" needs the code to be understood. Spell out the concrete
case, as in "A pass that recorded no draws in the last frame is not recorded again". Short text is good only when a
reader understands it without the code.

Leave out facts nobody needs. Do not argue against a misreading nobody would have. Use the common term, "texture
array" and not "layered image set".

## Doc comments and inline comments

Do not use dashes, colons or semicolons as sentence punctuation in a doc comment or an inline comment.

Comments are few. A comment or a doc exists only for a fact that the code and the names do not show. A function whose
name and signature say everything has no doc.

A doc says what the thing is and how to use it, usually in one or two sentences. It describes the code as it is now.
It does not hold any of these.

- Design reasons.
- Comparisons to sibling functions or types.
- References to callers or to other features.
- History, such as "now in", "used to" or "moved from".
- A comment left in place of removed code.
- Names of libraries, unless the reader must know the library to use the thing.
- A field by field description of a result that the type already shows.
- A mention of the project the code came from, of its files or of its functions. The code is prismarine's own now.

History and design reasons go in the commit message. Longer reasoning goes in a spec under `docs/specs/`.

A function doc leads with a verb, as in "Packs the draws by pipeline. Returns the packed rows and their count."

An inline comment carries a reason or a constraint that the code cannot show. A comment that restates the line below
it, a visible type or the doc of the called function is removed.

State a fact that holds across a file once, on the library or the class. Do not repeat it on every function or in
every test.

Keep parameter and return descriptions where a doc has them. Reword inside them and do not delete them. Document
every parameter of a function or none.

A style pass is also a correctness pass. Check that a reworded doc is still true. Fix a doc that describes removed
behaviour or a stale library.

## Descriptions of settings and options

A description is one or two sentences. It says what the setting does and gives its default. A measured effect or a
warning that changes the choice of a user may follow in one more sentence.

The behaviour of one setting goes in its help text or its row of a reference table. It does not get a section of its
own in a page.

## Error messages and log lines

An error message states the one case that happened, mentions the step and gives the fix, in one or two short
sentences. Explanations go in the documentation.

A message that covers several causes is split. Find the place in the code that knows the cause. Give each case its own
message there.

A log line states one event in the same plain wording. A fallback that changes a result is stated in a line that is
always visible, with the value in use.

## Pages and documents

These rules are for `README.md` and the pages under `docs/areas/`, `docs/specs/` and `docs/plans/`.

Write flowing paragraphs and address the reader as "you" on a page for users of the toolkit. Join related clauses, as
in "A retained pass costs nothing while its inputs stay the same, while a changed input records it again". Do not chop
the text into one short sentence per line.

Keep each sentence to one idea. Split a chain of "which", "so that" or trailing "-ing" clauses.

Say "does not" or "not" for a fact, not "never".

A heading is a plain noun phrase, such as "Frame plans" or "Thread roles".

Use typical, concrete examples, a real pass or a real texture format, in place of abstract notions.

Stay compact. The behaviour of a field goes in a reference table. The prose adds only what the table cannot say. Do
not state a fact in the introduction and again in its own section.

A page for users does not describe internals, such as the layout of a cache directory, generated files or the order in
which settings resolve. A spec under `docs/specs/` is the place for those.

A page for users is read by one person on their own computer, who follows it step by step. These rules come from
reviews of such pages.

- Say what to do in concrete terms. "Each platform needs the tools of a Flutter desktop app" or "link your SDK there
  once" leave the reader guessing; list the tools, or say which link to make from where to where.
- Explain what a file or a setting is for before you give its name, as in "each version of prismarine works with one
  engine release, and `RELEASE` holds its name".
- Leave out what the reader does not act on: how a value is stored ("the array"), how a tool works inside ("compiles
  each crate for both CPUs"), or which function prepares a file.
- Speak of the reader's computer. "Each machine", "every machine" or "a machine that holds the tree" describe our own
  setup, not the reader's.
- Use a verb in its plain sense. A variable sets where a folder is; it does not "move" the folder.
- Put every command into a fenced code block with its language, such as `sh` or `powershell`, never into an
  indented block or into a sentence the reader has to copy from.
- Give one topic one paragraph. A step that only one platform needs, such as Windows, gets its own paragraph.
- Write what stays true. A state that is about to change, such as a repository that is private for now, does not go
  into the steps.
- Fix a fact that is no longer true as soon as you see it, such as a build failure that a later change fixed.
- Check each sentence by asking whether a newcomer could act on it without the code. If not, rewrite it or drop it.

The pages under `docs/memory/` are lists of rules, decisions and state. Their entries are short statements in the same
wording.

Wrap a Markdown file at about 120 columns. A wrapped line must not start with "- ", since it would render as a list
item.

## Figures and debug views

A title says what is plotted, on which data and for which comparison, as in "Frame times of the sample scene on Metal
and on Vulkan, 2,000 frames each". A title is not a sentence that argues a conclusion. The conclusion goes in the
legend or in the text.

A label uses words. "Lower is better" replaces an arrow. "From 14 ms to 9 ms" replaces an arrow between two numbers. A
figure has no text arrows and no drawings made of characters.

## Names and terms

The toolkit is "prismarine", in lower case, also at the start of a sentence. `prismarine_<function>` is a package and
appears in code, paths and commit messages only.

Code, comments and docs do not mention a game. mcsm appears only where it matters now, as a user of prismarine in the
specs and plans of the split.

## Check before handing over

Reread new text against these rules while writing it. Then search the added lines for these.

- The openers What, Where, How, Who, Whether, When, Which and Why.
- A sentence that ends in "by", "under", "in", "on", "for", "with", "to" or "from".
- The banned words of the list above.
- ", so ", "so that", "because", "unlike" and ", and ".
- A dash, a colon or a semicolon inside a comment.

No automatic check exists yet.
