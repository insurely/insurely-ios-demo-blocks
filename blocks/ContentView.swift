//
//  ContentView.swift
//  blocks
//

import SwiftUI

struct SheetView: View {
    @Environment(\.presentationMode) var presentationMode

    @ObservedObject var viewModel = ViewModel()
    @Binding var config: String

    var body: some View {
        WebView(viewModel: viewModel, config: config)
    }
}

struct ContentView: View {
    @State private var showingSheet = false
    @State private var config = "{}"

    var body: some View {
        VStack(spacing: 20) {
            Button("Data Collection", action: {
                config = """
                    {
                        config: {
                            customerId: 'replace-me',
                            configName: 'replace-me'
                        }
                    }
                """
                showingSheet.toggle()
            })
            .fullScreenCover(isPresented: $showingSheet) {
                SheetView(config: $config)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
