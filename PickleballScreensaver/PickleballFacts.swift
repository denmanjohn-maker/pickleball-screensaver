import Foundation
import ScreenSaver

/// Persisted toggle for the rotating facts card.
struct TipSettings {
    var enabled = true

    private static let moduleName = "com.pickleball.screensaver"
    private static var defaults: ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    static func load() -> TipSettings {
        var s = TipSettings()
        if let d = defaults, d.object(forKey: "ShowPickleballTips") != nil {
            s.enabled = d.bool(forKey: "ShowPickleballTips")
        }
        return s
    }

    func save() {
        guard let d = Self.defaults else { return }
        d.set(enabled, forKey: "ShowPickleballTips")
        d.synchronize()
    }
}

/// Rules, history, strategy, and etiquette one-liners for the rotating card.
enum PickleballFacts {
    static let all: [String] = [
        // History
        "Pickleball was invented in the summer of 1965 on Bainbridge Island, Washington, by three dads improvising a game for their kids.",
        "Legend says the game was named after the Pritchards' dog, Pickles — but records show Pickles the dog came after the game.",
        "The name likely comes from “pickle boat” — a rowing crew thrown together from leftover oarsmen, like the game's borrowed gear.",
        "Pickleball became Washington State's official sport in 2022.",
        "Pickleball has been one of the fastest-growing sports in America for years running.",
        "The first permanent pickleball court was built in 1967 in the backyard of Bob O'Brian, a neighbor of co-inventor Joel Pritchard.",

        // Rules
        "The 7-foot no-volley zone beside the net is called the kitchen — you can't hit a volley while standing in it.",
        "You may stand in the kitchen any time; you just can't strike a volley while you're in it — or fall into it afterward.",
        "The kitchen rule includes momentum: if your volley carries you into the kitchen, it's a fault even after the ball is dead.",
        "If your paddle or even your hat lands in the kitchen during a volley, that's a fault too.",
        "Under side-out scoring, only the serving side can win a point.",
        "Games are played to 11, win by 2.",
        "The serve must be struck with an upward arc and contact below the waist.",
        "Serves must clear the kitchen: a serve that lands on the kitchen line is a fault, but any other line is good.",
        "The double-bounce rule: the ball must bounce once on each side before either team may volley.",
        "If a serve clips the net and lands in, play on — the “let” serve was abolished in 2021.",
        "In singles, you serve from the right side when your score is even and the left when it's odd.",
        "In doubles, the score is called as three numbers: your score, their score, and the server number.",
        "The very first serving team of a doubles game gets only one server — that's why the game starts at 0-0-2.",
        "Call the score before serving — once it's called, you have 10 seconds to serve.",
        "A regulation court is 20 by 44 feet — the same size for singles and doubles.",
        "The net is 36 inches high at the sidelines and sags to 34 inches at the center.",
        "An outdoor pickleball has 40 holes; indoor balls have 26 larger ones.",
        "Tournament balls must bounce 30–34 inches when dropped from 78 inches onto granite.",
        "A paddle's combined length and width may not exceed 24 inches.",

        // Shots & lingo
        "The third-shot drop — a soft shot into the kitchen — is how the serving team earns its way to the net.",
        "Dinking is the soft kitchen-to-kitchen rally that wins points with patience instead of power.",
        "An Erne is a legal volley taken from outside the sideline beside the kitchen, named for Erne Perry.",
        "A Bert is an Erne poached across the front of your own partner.",
        "An ATP — “around the post” — is a legal winner that travels outside the net post and never crosses over the net.",
        "Poaching is crossing into your partner's side to take a volley — aggressive, and often the right play.",
        "Stacking lets doubles partners keep their preferred sides of the court after every rally.",
        "A “banger” is a player who drives every ball hard — beat them with soft resets into the kitchen.",
        "A “falafel” is a shot hit with a dead paddle that flops short of the net.",
        "“Opa!” is shouted in some rec games after the third shot, signaling open volleying.",
        "Skinny singles uses only half the court — a great drilling game for footwork and accuracy.",

        // Strategy & etiquette
        "Return the serve deep — it buys you time to reach the kitchen line behind it.",
        "Get to the kitchen line as a pair: the gap between stranded partners is where points leak.",
        "Keep your paddle up at chest height whenever you're at the kitchen line.",
        "Watch the ball meet the paddle — most mishits come from looking up early.",
        "Talk on middle balls: by convention the forehand player takes them.",
        "A ball coming at your shoulder at the kitchen line is usually sailing out — let it go.",
        "Backspin dinks bounce lower and are much harder to attack.",
        "The reset — a soft block into the kitchen — turns defense back into a neutral rally.",
        "Advanced rallies are won by the soft game: far more dinks than drives.",
        "The lob is risky against tall players, but deadly against ones glued to the kitchen line.",
        "The paddle sweet spot sits slightly above the center of the face — aim contact there.",
        "Wear real court shoes: most pickleball injuries come from lateral moves in running shoes.",
        "Rally scoring or not, the serve is the only shot you fully control — build a repeatable one.",
    ]
}
