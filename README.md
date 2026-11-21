# slopmid

hey what if i didn't have to care about managing midi channels
and pretend i'm making EDM with every instrument standing on
its own like a maniac

what if the computer managed my midi channels for me like how
it manages OPL channels when its being fed a midi

wouldn't that be nice

## synthesis

uses slopgs for now lol

## midi channel allocation (oversimplified)

clips (well, "patterns") has its own tracks, tracks can only have ONE patch each, songs are a collection of clips

at any given moment, a track takes the lowest MIDI channel number first

so if a track is busy (i.e. playing a note) at midi ch1, but ch2 is free, another track will take that

CC is remembered per slopmid track, so MIDI ch/tracks will multiplex between slopmid tracks

except for rhythm, it initially takes midi ch 10 as usual

but as you add more rhythm channels, it allocates backwards
from ch16 upto ch11, it uses the `USE RHYTHM PART` gs message
to turn them so, this eats up on your melodic channel
allocation

why the limitation? because on rearranging part assignments, msgs will kill every sound and you don't want that in the middle of the track :(

slopmid will resolve the max rhythm "polyphony" before playing so it can reserve beforehand.

## controls

Controls are similar to what you find in FL Studio, with the exceptions:

- ctrl+click on a point off pitch bend and pan will bring the point back to defaults
- ctrl+d (not ctrl+b) duplicates
