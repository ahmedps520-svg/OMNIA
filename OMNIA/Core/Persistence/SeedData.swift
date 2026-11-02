import Foundation
import SwiftData

/// Built-in personas and prompt templates, inserted once on first launch. Users can edit or
/// delete them like their own.
enum SeedData {
    private static let seededKey = "seed.v1.installed"

    @MainActor
    static func installIfNeeded(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        personas.forEach { context.insert($0) }
        templates.forEach { context.insert($0) }
        try? context.save()
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    static var personas: [Persona] {
        [
            Persona(name: "OMNIA", symbol: "circle.hexagongrid",
                    systemPrompt: "You are OMNIA, a private assistant running entirely on the user's device. Be accurate, clear and concise. Use Markdown when it improves readability, and say so when you are unsure.",
                    isBuiltIn: true),
            Persona(name: "Analyst", symbol: "chart.bar.doc.horizontal",
                    systemPrompt: "You are a rigorous analyst. Break problems into parts, state assumptions, weigh evidence and end with a clear conclusion. Prefer tables and numbered steps for structure.",
                    temperature: 0.4, isBuiltIn: true),
            Persona(name: "Engineer", symbol: "chevron.left.forwardslash.chevron.right",
                    systemPrompt: "You are a senior software engineer. Give correct, idiomatic, production-quality code with brief explanations. Point out edge cases, performance and security concerns.",
                    temperature: 0.3, isBuiltIn: true),
            Persona(name: "Writer", symbol: "text.quote",
                    systemPrompt: "You are an expert editor and writing coach. Improve clarity, rhythm and tone while preserving the author's voice. Explain significant edits briefly.",
                    temperature: 0.8, isBuiltIn: true),
            Persona(name: "Tutor", symbol: "graduationcap",
                    systemPrompt: "You are a patient tutor. Explain concepts step by step with intuitive examples, check understanding with a short question, and adapt to the learner's level.",
                    temperature: 0.6, isBuiltIn: true),
            Persona(name: "Concise", symbol: "text.alignleft",
                    systemPrompt: "Answer as briefly as possible while staying correct. No preamble, no repetition of the question.",
                    temperature: 0.5, isBuiltIn: true)
        ]
    }

    static var templates: [PromptTemplate] {
        [
            PromptTemplate(title: "Summarize", body: "Summarize the following in five bullet points, then give a one-sentence takeaway:\n\n", category: "Writing", isBuiltIn: true),
            PromptTemplate(title: "Improve writing", body: "Improve the clarity and flow of this text without changing its meaning. Show the revised version, then list the main changes:\n\n", category: "Writing", isBuiltIn: true),
            PromptTemplate(title: "Draft an email", body: "Draft a clear, friendly email that accomplishes the following. Keep it under 150 words:\n\n", category: "Writing", isBuiltIn: true),
            PromptTemplate(title: "Translate", body: "Translate the following into natural, fluent English, preserving tone and formatting:\n\n", category: "Writing", isBuiltIn: true),
            PromptTemplate(title: "Review code", body: "Review this code for bugs, edge cases, readability and performance. Suggest concrete improvements with code:\n\n```\n\n```", category: "Code", isBuiltIn: true),
            PromptTemplate(title: "Write tests", body: "Write thorough unit tests for the following code, covering normal cases, edge cases and failures:\n\n```\n\n```", category: "Code", isBuiltIn: true),
            PromptTemplate(title: "Explain an error", body: "Explain what causes this error and how to fix it, step by step:\n\n```\n\n```", category: "Code", isBuiltIn: true),
            PromptTemplate(title: "Pros and cons", body: "Lay out the pros and cons of the following in a table, then give a recommendation with reasoning:\n\n", category: "Analysis", isBuiltIn: true),
            PromptTemplate(title: "Decision matrix", body: "Help me decide between these options. Identify the criteria that matter, score each option and explain the result:\n\n", category: "Analysis", isBuiltIn: true),
            PromptTemplate(title: "Explain simply", body: "Explain the following as if to a curious beginner, using an everyday analogy, then add one level of depth:\n\n", category: "Learning", isBuiltIn: true),
            PromptTemplate(title: "Quiz me", body: "Create a five-question quiz about the following topic. Ask one question at a time and wait for my answer:\n\n", category: "Learning", isBuiltIn: true),
            PromptTemplate(title: "Brainstorm", body: "Brainstorm twelve diverse, specific ideas for the following. Group them by theme:\n\n", category: "Ideas", isBuiltIn: true)
        ]
    }
}
