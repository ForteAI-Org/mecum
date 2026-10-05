//
//  Usage.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// Usage is the help text.
enum Usage {

    static let text = """
    mecum: drive a Mac application from the terminal through the Perception and Engine layers.

      mecum --chat ["prompt"] [--provider claude|codex] [--model <name>]
                                              chat using your signed-in provider; --chat --help for options
      mecum --chat --resume <UUID|last>         continue a saved conversation

      mecum windows <app>                      the window census: what would be driven, what is a pop-up
      mecum scene   <app> [--json]             perceive the interaction window and print the text map
      mecum peek    [--sections-only] [--labels]    live boxes over the frontmost app; peek --help for options
      mecum act     <app> <target> [options]   resolve the target by name, act, verify, report the outcome
      mecum select  <app> <dropdown> <item> --seat   open and select in one background menu operation
      mecum type_text    <app> <field> <text> [--append] [--section <name>] --seat
      mecum press_key    <app> <key> [--modifier cmd|shift|opt|ctrl]... [--count <1-20>] --seat
      mecum scroll       <app> <up|down> [--target <name>] [--lines <1-50>] [--section <name>] --seat
      mecum drag         <app> <from> (--to <target> | --dx <points> [--dy <points>] | --dy <points>)
                         [--section <name>] --seat
      mecum context_menu <app> <target> <item> [--section <name>] --seat
                                              the app's five input tools, one verified action each
      mecum batch   <app> --window <title> --seat [options] -- <step> --then <step> ...
                                              run several steps in one Seat lifetime
      mecum memory  status | traces | trace <id> | event <id> | <app>
                                              read the living memory with no application open

    <app> is a bundle id (com.adobe.PremierePro) or an application name (Premiere); the match is
    case-insensitive and a name may be a prefix. The seven actions are the app's tools, read by the
    same decoder: a verb, a value, a key, a modifier, a number or a drag's end means here what it
    means to the model, with the same defaults (verb click, replace on, count 1, lines 3).

    act options:
      --verb click|double_click|triple_click|right_click|set_toggle   default click
      --value on|off                                                  set_toggle only, and required by it
      --section <name>                                                a panel name that disambiguates a shared label
      --dry-run                                                       resolve and report, perform nothing
      --allow-destructive                                             permit a target whose label names a destructive act

    input options: type_text --append adds after what the field holds (default replaces it); press_key
    takes --modifier once per modifier and a key that is return, tab, escape, space, delete, left, right,
    up, down, a letter or a digit, in any case; drag ends on --to <target> or at an offset --dx/--dy in
    points (within 5000), never both. Numbers are decimal digits. select and the five inputs run on the
    Seat only; act may run on the real screen without --seat.

    words: every option is checked against the command: an unknown, repeated (but --modifier) or valueless
    option is refused before anything runs. A word is passed as typed, Unicode included; nothing is
    evaluated. Write -- before a word that would read as an option or a separator: `-- --then` is the
    text --then, `-- --` the text --, and `--section -- --x` the section --x. In a batch's header the
    same holds (`--window -- --Window`, `batch -- --App`); the first -- that escapes nothing starts the steps.

    common options:
      --knowledge <dir>          where memory lives (its memory.sqlite); default ~/Library/Application Support/Mecum/Knowledge
      --evidence <dir>           select: save captures; batch: dropdown captures in step-N subfolders
      --window <title>           with --seat: require one exact window title (for example "I/O Setup")
      --seat                     scene, the actions and batch: drive in the background on the Seat's virtual
                                 display instead of the real screen; the window is adopted, driven, returned
      --allow-unvalidated-build  with --seat: the Driver's research opt-in for a macOS build its ledger has
                                 not validated

    batch example (with New Paths already open):
      mecum batch "Pro Tools" --window "New Paths" --seat --allow-unvalidated-build -- \\
        select "Mono" "Stereo" --then \\
        act "Auto-create sub paths" --verb set_toggle --value on --then act "Create" --then \\
        type_text "Name" "Bus 1" --then press_key return

    Batch steps are any of the seven actions, written as their direct command without the app:
    act, select, type_text, press_key, scroll, drag, context_menu. Put shared options before --. The app
    is specified once. Every step is decoded before adoption; one refused step refuses the batch.
    Each step reads the window again. Failure, ambiguity, unverified effects or a lost target stop the batch;
    a verified set_toggle that is already on/off continues. Earlier effects remain, with no rollback or replay.
    The final step may close the window. Changing windows between steps and batch --dry-run are not supported.

    memory: status says where the archive is, how it stands and what it holds per application; traces lists
    the traces, most recent first (--before <order>, --limit <n>); trace <id> lists one trace's calls and
    observations in order (--after <order>, --limit <n>); event <id> shows one event with its call, typed
    arguments, states, times, result, effect, samples and scenes; <app> (or app <app>) its Brain, by bundle
    id even when the app is not installed, or by name, ambiguity answered with candidates. --detail writes
    typed texts, titles and labels. A missing, empty or unreadable archive exits 1 and nothing is created.
    Ctrl+C (or SIGTERM) stops scene, an action or a batch: no new action or step starts, what is known is
    recorded, the window is returned and the Seat's display taken down, the memory closed, then the process
    exits 130 (143 for SIGTERM); a second signal starts nothing more. A process killed outright (SIGKILL, a
    crash) may leave a call planned or started in the memory, which memory event shows as such.

    Screen Recording and Accessibility must be granted to the terminal that runs this.
    select uses native menu actions when exposed; custom dropdowns use a routed opener and visible-row keyboard selection.
    Both the current value and desired item must be readable in a custom menu. The closed dropdown verifies success.
    """
}
