# texturewrangler

let's design and implement non-destructive texture editor:
- fast, responsive native ui in imgui, embedded lua and c++, target 60fps. see ../teidraw and ../slopstudio for good examples of fast reliable imgui projects
- responsiveness is the #1 priority - tedious iteration kills momentum
- all non-performance-critical code is lua, ideally the c++ side is kept as slim as possible in complexity, reducing to the core graphics api and high performance primitives. this is to avoid wasting time chasing memory safety and crashes. the embedded lua setup should also include plenty of debugging infra as well
- structure code in a way that is maintainable and debuggable for an LLM first - we don't wanrt to thrash chasing some cpp or build system footgun
- extensive headless testing every step of the way + memory safety smoke tests (asan and stuff) to catch subtle errors early. try to exercise edge cases likely to misbehave
- set up the build system to avoid footguns from day 1. for a small projects like this we could even do 1 compilation unit, no intermediate object files and just avoid c++ constructs that slow down compilation
- take extra time to plan out and design the architecture and UX right, polished and maintainable from the start. you want it to be as well defined as possible before starting, and do research into similar projects + check in with me if needed to figure out the details of the design
- commit this SEED.md too, as the initial brainstorm
- feel free to pull in any extra dependencies needed on both the c++ and lua side but make sure to prefer small deps that are either easy to pull in from nixpkgs or vendorable 
- target windows first (daily driver) but also build linux
- build should produce a standalone folder with all the necessary dlls etc


# functionality

this is a tool hyper focused on procedurally shaping and editing textures, hyper specialized for retro textures (n64-ps2 era at most). the focus is to make it as easy and frictionless as possible to iterate on this type of texture. 

paste and drag&drop image from windows explorer and clipboard. it gets added as a layer

non-destructive editing, everything is a layer: everything is done through modifier layers: modifier layer to downscale -> remove it -> back to full res original image i pasted in

all external assets should be copied into the project folder

all projects are automatically put into a standard project dir location

new project/open project flow when starting the app with a list of projects. default name to a random string of dictionary words with option to rename later (should also be renamable while the project is open ideally).

export any partial or complete result:
default export is obviously the final composite, but at any point in the chain, an export layer can be added (and then picked by name when exporting or adding an extra export location). export final composite does not require an export layer, it implicitly acts as if there was an export layer at the very top

there should be a panel that shows the partial composite at the selected layer

textures always start transparent and always have an alpha channel

export locations:
defaults to project folder, optionall add extra exports to specific locations (useful if you want to automatically overwrite the texture in a godot project for example)

some ideas for layers (but do deep research on procedural texture techniques that fit the goals and add anything that seems like a worthy primitive):

- each layer has global opacity multiplier + visibility
- standard blending modes + alpha multiply mode which is basically an opacity mask. 2 options: only apply to layer below, or apply to the whole partial composite at this point
- various color grading adjustments, ideally without layering too many things together. for example, i find it annoying in gimp how I have to use some combination of contrast/hue/curves as separate filters when it would be easier if there was one set of controls to rule them all thats flexible enough
- downscale with various filters and techniques
- downsample color palette with various adjustments and optional dithering
- adjust/re-generate color pallette procedurally with some parameters
- paint layer: just arbitrary paint with your standard brush size, feather, color picker (only allow palette colors if we're after color downsampling steps)
- custom brush: use existing layer (including hidden ones) as a brush
- noise layer: various types of noise with params
- seamless tiling layer - automatically makes the texture tile, with some tunables
- grouping any number of layers together to use their composite as if it was a baked image as a layer (with a toggle that decides whether it's a composite of just the group or everything below + the group)

you can also take inspiration from some of the procedural stuff in ../cosmic2d 's sprite editor

ui should have no floating  stuff - all resizable panels tiled. 

there should be a panel preview of only the selected layer where applicable.

all the previews should show a 4x4 tile (optionally toggleable to just a single tile)

style imgui with a nice dark theme, see ../cosmic2d and ../slopstudio

ctrl+u and a menu option as alternatives to dragging files in (in situations where file drag is broken somehow)

follow same clean ux principles as teidraw and cosmic. long undo, autosaving, seamless editing with no confirming/manually saving anything. 

# dev env and repo
- create a nix flake with all the development tools and deps and always run things through nix develop
- you are running under nixos in wsl2 on a win11 host. WSLg avaiable, windows interop available and windows host reachable at cutestation.soy (local ip if needed)
- make sure there is a dense orientation for the project so a fresh session can orient quickly and pick the work right back up

some examples of methods used to manipulate textures in the style that I want https://www.youtube.com/watch?v=_sQ5Ho34Dws pull the transcript from this, there's yutu logged into my yt and yt-dlp with cookies-from-browser firefox)

anything i told you in this initial prompt should not be rediscovered in future sessions e.g the WSL2 envrionment and what's available and how to use it so persist all of that in the orientation

commit in logical units as you go always, co-signing with your model slug

always test things directly, use your vision extensively to smoke test and verify things to avoid human verification until you exhaust things you can test autonomously. always prefer testing methodologies that don't steal focus or screen space from the human, but if necessary feel free to steal focus and screen when absolutely needed
