import SwiftUI

struct CalendarScreen: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedTab: MainTabView.AppTab
    @State private var showDatePicker = false
    @State private var gameSearchText = ""
    
    
    private var displayedEvents: [SportsEvent] {
        let query = gameSearchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            return viewModel.eventsForSelectedDate
        }

        return viewModel.events.filter { event in
            event.title.localizedCaseInsensitiveContains(query) ||
            event.league.localizedCaseInsensitiveContains(query) ||
            event.sport.localizedCaseInsensitiveContains(query)
        }
    }
    
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 16) {
                
                header
                
                dateButton
                
                gameSearchBar
                
                sportFilterBar
                
                eventsHeader
                
                eventsList
            }
            .padding(.top, 18)
        }
        .sheet(isPresented: $showDatePicker) {
            VStack {
                EventCalendarView(
                    events: viewModel.events,
                    bars: viewModel.filteredBars,
                    useVisibleMapRegionOnly: viewModel.calendarUsesVisibleMapRegionOnly,
                    selectedDate: $viewModel.selectedDate
                ) {
                    withAnimation(.spring()) {
                        viewModel.selectedBar = nil
                        viewModel.selectedEvent = nil
                        viewModel.dateChanged()
                        showDatePicker = false
                    }
                }
                .padding()
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            viewModel.loadGamesFromSupabase()
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calendar")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.black)
            
            Text("Choose a date, then find where to watch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
    
    private var dateButton: some View {
        Button {
            showDatePicker = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selected date")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(viewModel.formattedSelectedDate)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.black)
                }
                
                Spacer()
                
                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.black)
                    .clipShape(Circle())
            }
            .padding()
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .padding(.horizontal)
    }
    
    private var eventsHeader: some View {
        HStack {
            Text("Events")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.black)
            
            Spacer()
            
            if viewModel.isLoadingEvents {
                ProgressView()
            }
        }
        .padding(.horizontal)
    }
    
    private var gameSearchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search game, team, league, or sport", text: $gameSearchText)
                .textInputAutocapitalization(.words)

            if !gameSearchText.isEmpty {
                Button {
                    gameSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal)
    }
    
    private var eventsList: some View {
        Group {
            if displayedEvents.isEmpty {
                Text("No events found for this date or search.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(displayedEvents) { event in
                            Button {
                                withAnimation(.spring()) {
                                    viewModel.selectEvent(event)
                                    selectedTab = .discover
                                }
                            } label: {
                                eventRow(event)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
            }
        }
    }
    
    private var sportFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.sports, id: \.self) { sport in
                    SportFilterChip(
                        sport: sport,
                        isSelected: viewModel.selectedSport == sport
                    ) {
                        withAnimation(.spring()) {
                            viewModel.sportChanged(to: sport)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
    
    private func eventRow(_ event: SportsEvent) -> some View {
        HStack(spacing: 14) {
            Image(systemName: viewModel.iconForSport(event.sport))
                .font(.title2)
                .frame(width: 42, height: 42)
                .background(Color.black)
                .foregroundStyle(.white)
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.black)
                
                Text("\(event.league) • \(event.sport) • \(viewModel.displayTime(for: event))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
