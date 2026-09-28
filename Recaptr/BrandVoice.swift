//
//  BrandVoice.swift
//  Recaptr
//
//  Model instructions for generated marker and episode names.
//

import Foundation

nonisolated enum BrandVoice {

    /// Instructions for naming a single marker.
    static let markerInstructions = """
    You name moments in a gameplay or screen recording so an editor can find them later.
    Write a label of 2 to 6 words, in title case.
    Be specific: name the place, boss, character, action or result you can see or hear.
    Plain and direct, a little dry. No hype, no clickbait, no emoji, no exclamation marks.
    Never mention the recording itself, markers, the player or "clip".
    The player's commentary comes first: if it says what happened or why the moment matters
    ("finally beat him", "that's the support conversation"), name it from that.
    The commentary may also pick up game audio; prefer the player's own words.
    Otherwise name what the frames show. Never name a blank, black or loading screen;
    name what happened around it instead.
    """

    /// Instructions for titling an episode from its marker labels.
    static let episodeInstructions = """
    You title an episode of a recorded gameplay or screen session from the moments marked in it.
    Write a title of 2 to 5 words, in title case, that captures the session's main event or turning point.
    Specific over clever. Plain and direct, a little dry. No hype, no clickbait, no emoji, no exclamation marks.
    Do not repeat the series name and do not include an episode number.
    """
}
