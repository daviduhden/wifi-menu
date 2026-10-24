# netstart quoting notes

These notes explain why `hostname_arg` applies two layers of escaping.
They are based on OpenBSD `netstart` revision 1.236. Recheck the source
before changing the encoding.

## Pipeline

For each `/etc/hostname.<if>` file, `netstart` does:

```sh
while IFS= read -- _line; do
	parse_hn_line $_line
done <$_hn
```

`parse_hn_line` stores the unquoted expansion in an array, rebuilds an
`ifconfig` command with single spaces, and `netstart` later runs it with
`eval`.

Consequences:

1. `read` has no `-r`, so it removes one backslash before the following
   character.
2. The unquoted `$_line` expansion splits on spaces and tabs before
   `eval`. Runs of spaces or tabs collapse to one space.
3. Quote characters are not syntax during that split; they survive into
   the rebuilt command and are interpreted by `eval`.
4. Therefore a value needs a standard single-quoted shell word, with one
   extra backslash layer so the word survives step 1.

## Encoding algorithm

Given a value that has already passed validation:

1. Build the POSIX single-quoted word: surround the value with `'` and
   replace every embedded `'` with `'\''`.
2. Replace every backslash in that word with two backslashes.

## Examples

| Original value | Shell word | File text | After `read` | After `eval` |
| --- | --- | --- | --- | --- |
| `it's` | `'it'\''s'` | `'it'\\''s'` | `'it'\''s'` | `it's` |
| `pa\ss` | `'pa\ss'` | `'pa\\ss'` | `'pa\ss'` | `pa\ss` |
| `a\'b` | `'a\'\''b'` | `'a\\'\\''b'` | `'a\'\''b'` | `a\'b` |
| `a b` | `'a b'` | `'a b'` | `'a b'` | `a b` |

Single spaces survive because the split produces two fields and the
rebuild inserts one space. Two consecutive spaces or a tab do not
survive; `validate_saved_value` rejects them.

## Decoding

`parse_saved_config` reads the first line of a saved file and handles two
generations:

- Current files contain doubled backslashes. `unquote_hn_field` first
  removes one backslash layer, then parses the resulting single-quoted
  shell word, converting `'\''` back to `'`.
- Older files contain a single backslash. They are parsed without the
  first layer. A legacy value containing a literal backslash next to a
  doubled backslash is ambiguous; reject it rather than guessing.

After decoding, the program re-renders the hostname file from the SSID and
passphrase. It does not copy the saved file verbatim, so extra lines in a
saved file are not installed.

## Verification without running the tool

For a static review, expand the encoding by hand for these values:

- `it's`
- `pa\ss`
- `a\'b`
- `a b`
- `a  b` (must be rejected)
- `a<TAB>b` (must be rejected)
- empty passphrase (no `wpakey` field)

A real end-to-end check requires OpenBSD, root and a disposable test
value. Do not run `wifi-menu`, `make install` or `netstart -n` as part of a
documentation-only change.
