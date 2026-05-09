import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const API_KEY = "123"

const leagues = [
  { id: "4387", sport: "NBA", league: "NBA" },
  { id: "4391", sport: "NFL", league: "NFL" },
  { id: "4424", sport: "Baseball", league: "MLB" },
  { id: "4328", sport: "Soccer", league: "Premier League" }
]

serve(async () => {
  const supabase = createClient(
    Deno.env.get("PROJECT_URL")!,
    Deno.env.get("SERVICE_ROLE_KEY")!
  )

  const allGames = []

  for (const league of leagues) {
    const url = `https://www.thesportsdb.com/api/v1/json/${API_KEY}/eventsnextleague.php?id=${league.id}`

    const response = await fetch(url)
    const data = await response.json()

    const events = data.events ?? []

    for (const event of events) {
      allGames.push({
        external_id: event.idEvent,
        source: "thesportsdb",
        title: event.strEvent,
        league: league.league,
        sport: league.sport,
        game_date: event.dateEvent,
        game_time: event.strTime ?? "Time TBD",
        home_team: event.strHomeTeam,
        away_team: event.strAwayTeam,
        status: "scheduled"
      })
    }
  }

  const { error } = await supabase
    .from("games")
    .upsert(allGames, { onConflict: "external_id" })

  if (error) {
    return new Response(JSON.stringify(error), { status: 500 })
  }

  return new Response(
    JSON.stringify({
      success: true,
      imported: allGames.length
    }),
    {
      headers: { "Content-Type": "application/json" }
    }
  )
})
