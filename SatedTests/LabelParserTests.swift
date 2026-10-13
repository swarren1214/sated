import CoreGraphics
import Testing
@testable import Sated

struct LabelParserTests {
    let usLabel = [
        "Nutrition Facts", "8 servings per container", "Serving size 2/3 cup (55g)",
        "Amount per serving", "Calories 230", "% Daily Value*", "Total Fat 8g 10%",
        "Saturated Fat 1g 5%", "Trans Fat Og", "Cholesterol Omg 0%", "Sodium 160mg 7%",
        "Total Carbohydrate 37g 13%", "Dietary Fiber 4g 14%", "Total Sugars 12g",
        "Includes 10g Added Sugars 20%", "Protein 3g",
    ]

    @Test func readsAUSLabel() {
        let reading = LabelParser.parse(usLabel)
        #expect(reading.calories == 230)
        #expect(reading.fat == 8)
        #expect(reading.carbs == 37)
        #expect(reading.protein == 3)
        #expect(reading.fiber == 4)
        #expect(reading.servingText == "2/3 cup (55g)")
        #expect(reading.servingGrams == 55)
        #expect(reading.isConsistent)
    }

    @Test func readsACanadianLabel() {
        let reading = LabelParser.parse([
            "Nutrition Facts", "Valeur nutritive", "Per 1 cup (250 mL) / pour 1 tasse (250 mL)",
            "Calories 110", "% Daily Value*", "Fat / Lipides 0 g 0 %", "Saturated / saturés 0 g",
            "Carbohydrate / Glucides 26 g", "Fibre / Fibres 0 g 0 %", "Sugars / Sucres 22 g",
            "Protein / Protéines 2 g",
        ])
        #expect(reading.calories == 110)
        #expect(reading.fat == 0)
        #expect(reading.carbs == 26)
        #expect(reading.protein == 2)
        #expect(reading.fiber == 0)
        #expect(reading.servingText == "1 cup (250 mL)")
    }

    @Test func usesThePerServingColumnAndLessThan() {
        let reading = LabelParser.parse([
            "Calories 140 280", "Total Fat 7g 9% 14g 18%", "Total Carb. 18g 7% 36g 13%",
            "Dietary Fiber <1g 2% 1g 4%", "Protein 2g 4g",
        ])
        #expect(reading.calories == 140)
        #expect(reading.fat == 7)
        #expect(reading.carbs == 18)
        #expect(reading.fiber == 0.5)
        #expect(reading.protein == 2)
    }

    @Test func caloriesPrintedOnTheirOwnLine() {
        #expect(LabelParser.parse(["Calories", "230", "Total Fat 8g"]).calories == 230)
    }

    @Test func numbersThatDontAddUpAreCaught() {
        // 8 read as 0: 0 g fat can't make 230 kcal with these carbs and protein.
        let misread = LabelReading(calories: 230, fat: 0, carbs: 37, protein: 3)
        #expect(!misread.isConsistent)
        #expect(LabelReading(calories: 0, fat: 0, carbs: 0, protein: 0).isConsistent)
    }

    @Test func findsThePanelAndIgnoresTheFrontOfThePackage() {
        func piece(_ text: String, _ y: CGFloat, x: CGFloat = 40) -> TextPiece {
            TextPiece(text: text, rect: CGRect(x: x, y: y, width: 160, height: 14))
        }
        var pieces = usLabel.enumerated().map { piece($1, 300 + CGFloat($0) * 18) }
        pieces.append(piece("20g Protein!", 60, x: 220))        // marketing, far above
        pieces.append(piece("Ingredients: oats, sugar", 900))  // well below the panel
        let panel = LabelParser.locatePanel(pieces)
        #expect(panel != nil)
        #expect(panel?.pieces.contains { $0.text == "20g Protein!" } == false)
        #expect(panel?.pieces.contains { $0.text == "Ingredients: oats, sugar" } == false)
        #expect(panel?.pieces.contains { $0.text == "Calories 230" } == true)
    }

    @Test func joinsPiecesOnTheSameRow() {
        let rows = LabelParser.rows([
            TextPiece(text: "230", rect: CGRect(x: 200, y: 100, width: 40, height: 20)),
            TextPiece(text: "Calories", rect: CGRect(x: 20, y: 102, width: 90, height: 20)),
            TextPiece(text: "Total Fat 8g", rect: CGRect(x: 20, y: 140, width: 120, height: 14)),
        ])
        #expect(rows == ["Calories 230", "Total Fat 8g"])
    }

    @Test func votesAcrossFrames() {
        var consensus = LabelConsensus()
        consensus.add(LabelReading(calories: 230, fat: 0, carbs: 37, protein: 3))   // one bad frame
        for _ in 0..<3 { consensus.add(LabelReading(calories: 230, fat: 8, carbs: 37, protein: 3)) }
        let confirmed = consensus.confirmed()
        #expect(confirmed.fat == 8)
        #expect(confirmed.hasCore)
    }
}
