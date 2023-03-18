# demofixup

A tool for fixing up Portal 2 demos recorded prior to game build 8873 to play on modern builds.

## Usage

Command-line usage:

    ./demofixup in.dem [out.dem]

If `out.dem` is not specified, it defaults to `in_fixed.dem`.

This usage means that on Windows, you can drag and drop a demo file onto the binary to convert it.

## Details

Portal 2 build 8873 removed the `point_survey` entity class. Unfortunately, this also broke all
previously recorded demos. This is because demos contain a section at the start called "data tables"
describing all entity classes and their associated networked properties. After the update, reading
this section triggers an error because it includes an entity - `point_survey` - which the client is
unaware of.

This entity was never actually used (it was an old playtesting feature). Thus, we can fix this by
simply removing the record of this entity from the datatables. There are two things that need
removing: the serverclass and the sendtable. The sendtable is easy - just omit its entry from the
list. The serverclass is harder, because every class is associated with an ID, and we want these to
be unmodified for other entity types. Moreover, the IDs must be in the range `0` to `n-1` where `n`
is the number of server classes. So, what we can do to solve this is replace the serverclass entry
for this with a duplicate of any other. We'll never use this entry, but that's not important: what
matters is that the game accepts it and plays the demo. Here, we replace `CPointSurvey` and
`DT_PointSurvey` with `CPointCamera` and `DT_PointCamera`.
