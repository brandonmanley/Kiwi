import Foundation

enum ArxivCategories {
    static let all: [String] = [
        "astro-ph.CO", "astro-ph.EP", "astro-ph.GA",
        "astro-ph.HE", "astro-ph.IM", "astro-ph.SR",
        "cond-mat.dis-nn", "cond-mat.mes-hall", "cond-mat.mtrl-sci",
        "cond-mat.other", "cond-mat.quant-gas", "cond-mat.soft",
        "cond-mat.stat-mech", "cond-mat.str-el", "cond-mat.supr-con",
        "gr-qc", "hep-ex", "hep-lat",
        "hep-ph", "hep-th", "math-ph",
        "nlin.AO", "nlin.CD", "nlin.CG", "nlin.PS", "nlin.SI",
        "nucl-ex", "nucl-th", "quant-ph",
        "physics.acc-ph", "physics.ao-ph", "physics.app-ph",
        "physics.atm-clus", "physics.atom-ph", "physics.bio-ph",
        "physics.chem-ph", "physics.class-ph", "physics.comp-ph",
        "physics.data-an", "physics.ed-ph", "physics.flu-dyn",
        "physics.gen-ph", "physics.geo-ph", "physics.hist-ph",
        "physics.ins-det", "physics.med-ph", "physics.optics",
        "physics.plasm-ph", "physics.pop-ph", "physics.soc-ph",
        "physics.space-ph"
    ]

    private static let displayNames: [String: String] = [
        "astro-ph": "Astrophysics",
        "astro-ph.co": "Cosmology and Nongalactic Astrophysics",
        "astro-ph.ep": "Earth and Planetary Astrophysics",
        "astro-ph.ga": "Astrophysics of Galaxies",
        "astro-ph.he": "High Energy Astrophysical Phenomena",
        "astro-ph.im": "Instrumentation and Methods for Astrophysics",
        "astro-ph.sr": "Solar and Stellar Astrophysics",
        "cond-mat": "Condensed Matter",
        "cond-mat.dis-nn": "Disordered Systems and Neural Networks",
        "cond-mat.mes-hall": "Mesoscale and Nanoscale Physics",
        "cond-mat.mtrl-sci": "Materials Science",
        "cond-mat.other": "Other Condensed Matter",
        "cond-mat.quant-gas": "Quantum Gases",
        "cond-mat.soft": "Soft Condensed Matter",
        "cond-mat.stat-mech": "Statistical Mechanics",
        "cond-mat.str-el": "Strongly Correlated Electrons",
        "cond-mat.supr-con": "Superconductivity",
        "nlin": "Nonlinear Sciences",
        "nlin.ao": "Adaptation and Self-Organizing Systems",
        "nlin.cd": "Chaotic Dynamics",
        "nlin.cg": "Cellular Automata and Lattice Gases",
        "nlin.ps": "Pattern Formation and Solitons",
        "nlin.si": "Exactly Solvable and Integrable Systems",
        "physics": "Other physics",
        "physics.acc-ph": "Accelerator Physics",
        "physics.ao-ph": "Atmospheric and Oceanic Physics",
        "physics.app-ph": "Applied Physics",
        "physics.atm-clus": "Atomic and Molecular Clusters",
        "physics.atom-ph": "Atomic Physics",
        "physics.bio-ph": "Biological Physics",
        "physics.chem-ph": "Chemical Physics",
        "physics.class-ph": "Classical Physics",
        "physics.comp-ph": "Computational Physics",
        "physics.data-an": "Data Analysis, Statistics and Probability",
        "physics.ed-ph": "Physics Education",
        "physics.flu-dyn": "Fluid Dynamics",
        "physics.gen-ph": "General Physics",
        "physics.geo-ph": "Geophysics",
        "physics.hist-ph": "History and Philosophy of Physics",
        "physics.ins-det": "Instrumentation and Detectors",
        "physics.med-ph": "Medical Physics",
        "physics.optics": "Optics",
        "physics.plasm-ph": "Plasma Physics",
        "physics.pop-ph": "Popular Physics",
        "physics.soc-ph": "Physics and Society",
        "physics.space-ph": "Space Physics",
        "hep-ex": "High Energy Physics - Experiment",
        "hep-ph": "High Energy Physics - Phenomenology",
        "hep-th": "High Energy Physics - Theory",
        "hep-lat": "High Energy Physics - Lattice",
        "nucl-ex": "Nuclear Experiment",
        "nucl-th": "Nuclear Theory",
        "gr-qc": "General Relativity & Quantum Cosmology",
        "quant-ph": "Quantum Physics",
        "math-ph": "Mathematical Physics",
    ]

    static func displayName(for category: String) -> String {
        displayNames[category.lowercased()] ?? category
    }

    /// Stable group ordering used by both Onboarding and Settings.
    private static let groupOrder = [
        "hep", "nucl", "astro-ph", "cond-mat", "quant-ph",
        "gr-qc", "math-ph", "nlin", "physics"
    ]

    static func grouped() -> [(key: String, values: [String])] {
        let groups = Dictionary(grouping: all) { cat in
            cat.split(separator: ".").first.map(String.init) ?? "other"
        }
        return groups
            .map { (key: $0.key, values: $0.value.sorted()) }
            .sorted { a, b in
                let ia = groupOrder.firstIndex(of: a.key) ?? .max
                let ib = groupOrder.firstIndex(of: b.key) ?? .max
                if ia != ib { return ia < ib }
                return a.key < b.key
            }
    }
}
