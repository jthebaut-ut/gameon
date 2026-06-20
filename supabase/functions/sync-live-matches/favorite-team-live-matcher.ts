import { FAVORITE_TEAM_MATCH_ALIASES } from "./favorite-team-match-aliases.ts"

const GENERIC_TOKENS = new Set([
  "club",
  "city",
  "football",
  "basketball",
  "hockey",
  "racing",
  "sport",
  "sports",
  "college",
  "united",
  "real",
  "inter",
  "atletico",
  "athletic",
  "sporting",
  "national",
  "team",
])

function normalizedSearchText(raw: string): string {
  return String(raw ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
}

function containsPhrase(phrase: string, text: string): boolean {
  if (!phrase) return false
  if (text === phrase) return true
  if (text.startsWith(`${phrase} `)) return true
  if (text.endsWith(` ${phrase}`)) return true
  return text.includes(` ${phrase} `)
}

function participantMatchesAlias(participant: string, alias: string): boolean {
  if (!participant || !alias) return false
  if (alias.length <= 2) return false
  if (GENERIC_TOKENS.has(alias)) return false
  if (participant === alias) return true
  if (alias.includes(" ")) return containsPhrase(alias, participant)
  if (alias.length <= 4) {
    return participant.split(" ").includes(alias)
  }
  return containsPhrase(alias, participant)
}

export function favoriteTeamAliasesMatchParticipants(
  aliases: string[],
  homeTeam: string,
  awayTeam: string,
): boolean {
  const participants = [homeTeam, awayTeam]
    .map(normalizedSearchText)
    .filter(Boolean)
  if (participants.length === 0 || aliases.length === 0) return false

  return aliases.some((alias) =>
    participants.some((participant) => participantMatchesAlias(participant, alias))
  )
}

export function followedCatalogTeamIdsForMatch(
  homeTeam: string,
  awayTeam: string,
  followedTeamIds: Set<string>,
): string[] {
  const matched: string[] = []
  for (const teamId of followedTeamIds) {
    const aliases = FAVORITE_TEAM_MATCH_ALIASES[teamId]
    if (!aliases?.length) continue
    if (favoriteTeamAliasesMatchParticipants(aliases, homeTeam, awayTeam)) {
      matched.push(teamId)
    }
  }
  return matched
}
