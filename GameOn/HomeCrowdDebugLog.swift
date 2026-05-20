import Foundation
import Supabase

enum HomeCrowdDebugLog {
    static func logSetPayload(venueId: UUID) {
        print("[HomeCrowdDebug] setPayload venueId=\(venueId.uuidString.lowercased())")
    }

    static func logSetSuccess(venueId: UUID) {
        print("[HomeCrowdDebug] setSuccess venueId=\(venueId.uuidString.lowercased())")
    }

    static func logSetError(_ error: Error) {
        if let pe = error as? PostgrestError {
            print(
                "[HomeCrowdDebug] setError code=\(pe.code ?? "nil") message=\(pe.message) details=\(pe.detail ?? "nil") hint=\(pe.hint ?? "nil")"
            )
        } else {
            print("[HomeCrowdDebug] setError code=nil message=\(error.localizedDescription) details=nil hint=nil")
        }
    }

    static func logVerifySelf(venueId: UUID?, setAt: String?) {
        let venueValue = venueId?.uuidString.lowercased() ?? "nil"
        let setAtValue = setAt ?? "nil"
        print("[HomeCrowdDebug] verifySelf homeCrowdVenueId=\(venueValue) homeCrowdSetAt=\(setAtValue)")
    }
}
