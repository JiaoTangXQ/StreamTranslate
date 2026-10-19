---
name: StreamTranslate Caption Workspace
description: Native dark caption reading with a supporting conversation brain map.
colors:
  surface: "rgb(5.5% 6.7% 8.2%)"
  sidebar: "rgb(8% 9.4% 11.4%)"
  foreground: "rgb(94% 94% 94%)"
  secondary: "rgb(69% 69% 69%)"
  line: "rgb(100% 100% 100% / 9%)"
  accent: "rgb(52% 77% 96%)"
  translation: "rgb(47% 78% 100%)"
  toolbar-highlight: "rgb(100% 100% 100% / 7%)"
  leaf-fill: "rgb(100% 100% 100% / 3.5%)"
  leaf-hover: "rgb(100% 100% 100% / 6.5%)"
typography:
  title:
    fontFamily: "system-ui"
    fontSize: "15px"
    fontWeight: 600
  body:
    fontFamily: "system-ui"
    fontSize: "13px"
    fontWeight: 400
  branch-label:
    fontFamily: "system-ui"
    fontSize: "12px"
    fontWeight: 600
  leaf-label:
    fontFamily: "system-ui"
    fontSize: "12px"
    fontWeight: 500
  leaf-detail:
    fontFamily: "system-ui"
    fontSize: "12px"
    fontWeight: 400
  toolbar-label:
    fontFamily: "system-ui"
    fontSize: "12px"
    fontWeight: 500
  metadata:
    fontFamily: "system-ui"
    fontSize: "11px"
    fontWeight: 400
rounded:
  topic: "8px"
  leaf: "6px"
  control: "6px"
  workspace: "12px"
  window: "16px"
spacing:
  tight: "5px"
  control-gap: "8px"
  status-gap: "10px"
  section-inset: "12px"
  reading-gap: "18px"
  outline-inset: "20px"
components:
  toolbar-icon:
    textColor: "{colors.secondary}"
    rounded: "{rounded.control}"
    size: "30px"
  toolbar-icon-selected:
    backgroundColor: "{colors.toolbar-highlight}"
    textColor: "{colors.accent}"
    rounded: "{rounded.control}"
    size: "30px"
  outline-pane:
    backgroundColor: "{colors.sidebar}"
    textColor: "{colors.foreground}"
    padding: "0 20px"
  topic-title:
    textColor: "{colors.foreground}"
    typography: "{typography.title}"
    rounded: "{rounded.topic}"
    padding: "11px 12px"
  mind-map-leaf:
    backgroundColor: "{colors.leaf-fill}"
    textColor: "{colors.foreground}"
    typography: "{typography.leaf-label}"
    rounded: "{rounded.leaf}"
    padding: "8px 9px"
  mind-map-leaf-hover:
    backgroundColor: "{colors.leaf-hover}"
---

# Design System: StreamTranslate Caption Workspace

## Overview

**Creative North Star: "Caption-first native workspace"**

This document describes the current macOS AppKit/SwiftUI caption workspace. Its scope is the floating caption panel and conversation brain map; it does not establish a new brand identity or restyle settings. “Caption-first native workspace” is an implementation description, not a user-approved creative metaphor.

The workspace uses dark reading surfaces, system type, SF Symbols, and a restrained blue family for translation and brain-map cues. Captions retain their own reading area; the brain map shows topic roots, named branches, and short leaf nodes joined by parent/sibling edges. Native controls preserve platform interaction and accessibility behavior.

**Key Characteristics:**

- Dark tonal separation between transcript and brain map.
- Selectable source text with a smaller blue translation beneath it.
- Real columns when space permits; native content tabs when compact.
- Topic and branch disclosure reveal short connected nodes; longer node explanations open on demand.

## Colors

The palette distinguishes two dark surfaces, two neutral text levels, and blue reading cues. The frontmatter preserves SwiftUI's normalized RGB channels as percentage CSS colors; it is the machine-readable token layer.

### Primary

- **Workspace blue (`accent`):** toolbar identity, selected toolbar controls, branch labels, topic-root fill/stroke, and graph connections. Topic roots apply 8% fill and 28% border opacity; parent-to-branch and branch-to-leaf edges use 50% and 36% respectively.
- **Translation blue (`translation`):** the second line of each caption pair. This is a separate observed color, not an alias of the workspace accent.

### Neutral

- **Reading surface (`surface`):** transcript and painted window rim. The interior workspace applies 96% opacity over its opaque rim background.
- **Brain-map surface (`sidebar`):** a slightly lighter supporting reading pane.
- **Reading foreground (`foreground`):** brain-map headings and leaf labels.
- **Secondary text (`secondary`):** metadata, optional node explanations, utility icons, and status text.
- **Divider (`line`):** one-point toolbar, column, and status boundaries.
- **Toolbar highlight (`toolbar-highlight`):** selected or hovered reusable icon buttons.
- **Leaf fill (`leaf-fill`):** the resting surface of a short leaf label.
- **Leaf hover (`leaf-hover`):** the brighter leaf label surface while its node is hovered.

Caption source lines use white with state-dependent opacity: the latest completed source is 97%, older completed sources 76%; translation uses 98% and 80% respectively. Streaming translation uses 90%. These are content states, not new palette primitives. The shell has a white 13% outline; the workspace toggle uses a white 4.5% fill.

## Typography

Use SwiftUI's system font and SF Symbols. `system-ui` in portable tokens denotes the platform system family; CSS sizes represent native point sizes numerically and do not imply a web runtime.

- **Title:** summary heading and discussion topic headings use the title role; advertising topic headings use a smaller semibold size (13 pt).
- **Body:** empty-state explanations use the body role, with native added line spacing (5 pt). Native line metrics remain in effect; no fixed CSS line-height is prescribed.
- **Branch label:** named branch disclosure labels use the semibold branch-label role in accent blue.
- **Leaf label:** short labels use the medium leaf-label role, with native added line spacing (3 pt).
- **Leaf detail:** optional explanations use the regular leaf-detail role, secondary text, and native added line spacing (4 pt).
- **Toolbar label:** the brain-map toggle uses the toolbar-label role; the workspace name is semibold at the same size.
- **Metadata:** topic counts, backend descriptions, status, and collapsed counts use the metadata role. Counts use monospaced digits. The AI omission notice is smaller (10 pt).
- **Captions:** source size follows the existing user setting; translation is one point smaller. Never replace that setting with the static brain-map text roles. Caption pairs have a tight internal gap and a larger gap between entries.

**The Source Then Translation Rule.** Place the spoken source first and its translation directly beneath it, regardless of source language.

## Layout

The floating panel has a painted interaction rim (6 pt) around the rounded workspace. Its minimum window width is 300 pt; minimum caption and expanded-summary heights are 184 pt and 360 pt. The toolbar occupies 38 pt followed by a one-point divider.

When the brain map is expanded and the inner content width reaches 760 pt, render a real transcript column and trailing brain-map column. This threshold is measured inside the rim, not against the outer window width. The brain-map pane starts at 344 pt and can be adjusted between 300 and 440 pt, further constrained by available width so at least 360 pt remains for captions. The column separator is one point of paint inside a nine-point drag target; accessibility adjustment changes the requested brain-map width in 20 pt steps.

Below that content threshold, the expanded workspace offers a native segmented selector, “字幕 / 脑图” (156 pt wide), with one visible pane at a time. The transcript retains its instance, scroll position, and selection identity across reflow. Hidden panes cannot receive focus or pointer input. Closing the brain map restores caption reading and returns focus to its toggle.

Transcript content has horizontal padding (22 pt) and top/bottom padding (12 pt). Entry spacing uses the reading gap. A bottom reading margin is at least 62 pt and grows to the measured quick-controls height plus 4 pt; control fading must not cover the latest line. Brain-map content uses the outline inset and 20 pt between topics. Branch rows connect from the root through an 18 pt edge lane and leaf rows through a 14 pt edge lane; each sibling shares its parent rail, and the final edge ends at its own node. The brain-map header and status footer remain outside the scrolling topic body. When that scroll viewport is shorter than 300 pt, branches default to collapsed; an explicit branch disclosure choice takes precedence across reflow.

**The Caption Reading Rule.** Preserve the transcript as a dedicated reading region; below the split threshold, switch panes rather than compressing two columns.

## Elevation & Depth

AppKit supplies the floating window's native shadow (`hasShadow = true`); the implementation sets no custom shadow radius, offset, or opacity. Interior depth comes from the lighter brain-map surface, subtle separators, and control state fills. Brain-map roots and leaves are visibly bounded graph nodes with no individual shadows; their fills, root borders, and connecting strokes establish hierarchy. The quick-control overlay is a separate existing native control surface; this document does not redefine its palette.

Controls fade using an ease-out transition (0.18 s) and omit that animation when Reduce Motion is enabled. There is no decorative animation on live text.

## Shapes

The outer window and inner workspace use their corresponding rounded tokens. Toolbar controls use the control radius. Topic roots use the topic radius with an accent border; leaf labels use the leaf radius and a subtle state fill. Graph edges are one-point strokes with round caps, with a vertical sibling rail and rightward arm to each child. Native segmented and bordered controls retain platform shapes rather than receiving an invented global radius.

## Components

### Toolbar controls

Reusable icon buttons occupy a square target and use a medium SF Symbol (13 pt). Resting icons use secondary text; selection uses the accent, and selection or hover reveals the shared highlight. Each control has a help label and accessibility label. The brain-map toggle is a separate plain button with horizontal padding (9 pt), height (28 pt), and a subdued fill. Its keyboard shortcut is Command-Shift-S; Escape collapses an expanded brain map. Keep native keyboard focus behavior; no custom focus-ring token is defined.

### Content navigation

Use the native compact segmented selector only when both captions and the brain map cannot retain reading columns. It chooses the visible pane without destroying either view. The selected pane remains fully interactive; the hidden pane is disabled and hidden from accessibility.

### Caption pairs

Each entry is a vertically stacked, selectable source and translation pair. The newest completed entry is brighter than older entries. Text wraps to the actual column width and determines its own height. User scrolling suspends automatic following; following resumes when scrolling ends at the bottom, with an eight-point bottom tolerance.

### Brain-map topics, branches, and nodes

Each topic is a bordered root disclosure button with a small accent dot, wrapped title, trailing chevron, and a node count when collapsed. Root padding uses the topic-title component; its height follows the wrapped title. The current topic opens by default while explicit disclosure choices persist. Advertising and sponsorship topics sit inside a separate collapsed disclosure group.

Every nonempty branch has a named semibold disclosure row, node count, and chevron; the generic “要点” title is shown as “概览”. Its hit area has a minimum height (30 pt). Connected leaves use short labels, with application content limits of 40 characters per label and 160 per optional explanation. More than three leaves initially show the first and last two; an explicit control reveals earlier nodes.

A node with an explanation is a plain disclosure button; its explanation starts collapsed. A node without an explanation is selectable text, and expanded explanations are selectable. Do not promise text selection on disclosure-button labels. Explanations may repeat information in sibling labels; the component does not guarantee semantic deduplication. Preserve the short-label hierarchy rather than substituting full paragraphs for nodes.

### Brain-map header, empty state, and status footer

The header uses “对话脑图”, count/backend metadata, and the reusable copy icon. Copy is disabled when there is no brain map; a checkmark acknowledges a successful copy until the next completed update. An empty brain map explains topic/branch organization, short nodes, and optional explanations in a title and short paragraph.

The footer separates update state from actions. It shows generation progress, a grouped-update message, pause status, or an error; it keeps native small bordered buttons for manual update/retry and pause/resume. Existing brain-map content remains readable during generation. The visible automatic-update description is approximately 30 seconds, not a guaranteed model-response time. The omission notice remains subordinate metadata.

## Do's and Don'ts

### Do:

- **Do** keep the transcript and brain map as separate reading regions.
- **Do** use native system type, SF Symbols, segmented selection, and bordered small action buttons.
- **Do** retain selectable captions, explanation text, and leaves without explanations; preserve explicit accessibility labels and keyboard access.
- **Do** preserve manual scrolling and disclosure choices across content updates and width changes.
- **Do** keep prior brain-map content visible while a grouped update is prepared.

### Don't:

- **Don't** apply this scoped workspace palette as an automatic redesign of settings or other windows.
- **Don't** replace the compact content selector with squeezed side-by-side columns.
- **Don't** treat the toolbar accent and translation blue as one identical source token.
- **Don't** add custom card shadows, decorative text effects, or a new brand metaphor to this workspace without a separate decision.
- **Don't** treat portable HTML/CSS previews as runtime SwiftUI or exact native-control rendering.

<!-- Source scope: StreamTranslate/Views/CaptionWorkspaceStyle.swift; FloatingCaptionView.swift; ConversationSummaryView.swift; ConversationMindMapView.swift; StreamTranslate/Windows/FloatingPanel.swift. Visual references: .impeccable/review/mindmap-1.9.1/summary-980-640.png; .impeccable/review/mindmap-1.9.1/summary-980-420.png; .impeccable/review/mindmap-1.9.1/summary-300-360.png; .impeccable/review/mindmap-1.9.1/summary-300-detail.png. Portable samples in .impeccable/design.json are approximations, not runtime UI. -->
