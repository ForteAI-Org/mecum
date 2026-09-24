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
      mecum batch   <app> --window <title> --seat [options] -- <step> --then <step> ...
                                              run several steps in one Seat lifetime
      mecum memory  <app>                      read-only: what the brain, routes and living memory remember

    <app> is a bundle id (com.adobe.PremierePro) or an application name (Premiere); the match is
    case-insensitive and a name may be a prefix.

    act options:
      --verb click|double_click|triple_click|right_click|set_toggle   default click
      --value on|off                                                  the state a set_toggle must reach
      --section <name>                                                a panel name that disambiguates a shared label
      --dry-run                                                       resolve and report, perform nothing
      --allow-destructive                                             permit a target whose label names a destructive act

    common options:
      --knowledge <dir>          where memory lives; default ~/Library/Application Support/Mecum/Knowledge
      --evidence <dir>           select: save captures; batch: dropdown captures in step-N subfolders
      --window <title>           with --seat: require one exact window title (for example "I/O Setup")
      --seat                     scene, act, select and batch: drive in the background on the Seat's virtual
                                 display instead of the real screen; the window is adopted, driven, returned
      --allow-unvalidated-build  with --seat: the Driver's research opt-in for a macOS build its ledger has
                                 not validated

    batch example (with New Paths already open):
      mecum batch "Pro Tools" --window "New Paths" --seat --allow-unvalidated-build -- \\
        select "Mono" "Stereo" --then \\
        act "Auto-create sub paths" --verb set_toggle --value on --then act "Create"

    Batch steps are select <dropdown> <item> or act <target> [--verb ...] [--value ...] [--section ...].
    Put shared options before --. The app is specified once. All arguments are checked before adoption.
    Each step reads the window again. Failure, ambiguity, unverified effects or a lost target stop the batch;
    a verified set_toggle that is already on/off continues. Earlier effects remain, with no rollback or replay.
    The final step may close the window. Changing windows between steps and batch --dry-run are not supported.

    Screen Recording and Accessibility must be granted to the terminal that runs this.
    select uses native menu actions when exposed; custom dropdowns use a routed opener and visible-row keyboard selection.
    Both the current value and desired item must be readable in a custom menu. The closed dropdown verifies success.
    """
}
