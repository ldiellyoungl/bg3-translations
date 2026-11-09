# Proficiency at a Glance

Marks weapons and armor in your inventory, containers and trade windows as Bad, Not Ideal or Good
for the character you have selected, so you can tell at a glance what that character should not wear.

## What it does

- **Bad:** the character is not proficient with the item. By default, also an item that works
  against a class feature, such as a shield or armor on a monk, or heavy body armor on a barbarian.
- **Not Ideal:** by default, an item that works against an AC bonus or a feat, such as body armor
  while Mage Armor is up, or a non-Finesse weapon for a Defensive Duelist. So is a Two-Handed weapon
  while an off-hand item is equipped, and the reverse.
- **Good:** none of the above.
- The Penalties tab chooses which of these count, and whether each counts as Bad or Not Ideal. When
  more than one applies, the worse rating wins.
- Items are rated for one character: the party member chosen in the trade window while trading,
  otherwise your selected character. Equipped items are rated for their wearer, and a Bad or Not
  Ideal one gets a badge on its equipment slot.
- Hover a badge to see why, for example "Not proficient: Longswords".
- Rated: weapons, shields, and armor worn on the body, head, hands and feet. Rings, amulets, cloaks,
  clothing, instruments, torches and consumables are never rated.
- Marked: containers, the character inventory, the pop-out bag, the party inventory, both sides of
  a trade, and the equipment slots. The hotbar, pickpocketing, alchemy, and Combine are not marked.
- Keyboard and mouse UI only. The controller UI is not marked.

## Requirements

- Baldur's Gate 3 Script Extender v33 or newer. On v32 the mod loads but shows no marks, and the
  Script Extender console says so.
- Mod Configuration Menu (MCM) is optional. Without it, the defaults apply.

## Install

- With a mod manager such as Vortex: install the archive, enable the mod, and deploy.
- By hand: put `ProficiencyAtAGlance.pak` in `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods`
  and enable it in the game's mod manager or BG3 Mod Manager.

## Load order

The mod replaces one of the game's UI library files, so it must load after any other mod that
replaces the same file:

- **Better Inventory UI:** load this mod after it. Otherwise no marks show at all.
- **BCPP** (Caites' character sheet and party panel mod, Nexus Mods 1580): load this mod after it.
  Otherwise hovering a mark in the character inventory, the pop-out bag, the party panel or a
  companion's chest explains nothing, and the equipment slots get no badges.

## Settings

Open Mod Configuration Menu and pick **Proficiency at a Glance**. The main options:

- **General:** Show proficiency marks, Show marks on equipped items, the two hover explanations,
  Show marks on Wares (off by default), Marks in Trade windows (Full, Subtle or Off), and Logging.
- **Penalties:** which class, AC, feat and other penalties count, and whether each section rates
  Bad or Not Ideal. Stealth Disadvantage is off by default.
- **Looks:** for each rating, any of Glow, Badge and Dot (Bad and Not Ideal also have Dim and
  Gray), plus its color and badge icon, and which corners the badge and dot sit in.

## Compatibility

- Works with Better Inventory UI and BCPP when it loads after them.
- Works with Better Containers, Better Trade Menu (including Camp Storage), and Companions Panel and
  Camp Chest Everywhere (its chest page).
- Most penalties are read from the game's rules, so a mod that lifts a limit also removes the
  matching mark.

## Credits

- Larian Studios, for Baldur's Gate 3 and the UI templates this mod builds on.
- Norbyte, for the Script Extender.
- Volitio, for Mod Configuration Menu.

## Licence

GNU General Public License, version 3, for the mod's own Lua and XAML. The game's templates in it
are Larian Studios'. See LICENSE and NOTICE.
