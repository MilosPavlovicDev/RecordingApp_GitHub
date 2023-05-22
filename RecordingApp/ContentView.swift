//
//  ContentView.swift
//  RecordingApp
//
//  Created by Milos Pavlovic on 21.5.23..
//

import SwiftUI
import AVFoundation
import Speech
import MessageUI
import Alamofire

struct MailComposer: UIViewControllerRepresentable {
    typealias UIViewControllerType = MFMailComposeViewController
    
    @Environment(\.presentationMode) var presentationMode
    var audioFilename: URL
    var transcription: String
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        @Binding var presentationMode: PresentationMode
        
        init(presentationMode: Binding<PresentationMode>) {
            _presentationMode = presentationMode
        }
        
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true) {
                self.presentationMode.dismiss()
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(presentationMode: presentationMode)
    }
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mailComposer = MFMailComposeViewController()
        mailComposer.mailComposeDelegate = context.coordinator
        
        mailComposer.setSubject("Audio Transcription")
        mailComposer.setMessageBody(transcription, isHTML: false)
        
        if let audioData = try? Data(contentsOf: audioFilename) {
            mailComposer.addAttachmentData(audioData, mimeType: "audio/wav", fileName: "recording.wav")
        }
        
        mailComposer.setToRecipients(["vpatricia@hiiiwav.org"])
        
        return mailComposer
    }
    
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {
        
    }
}

struct ContentView: View {
    @State private var isRecording = false
    @State private var audioRecorder: AVAudioRecorder?
    @State private var audioFilename: URL?
    @State private var transcribedText: String = ""
    @State private var showMailComposer = false
    
    var body: some View {
        VStack {
            ZStack {
                Text(transcribedText)
                    .font(.system(size: 1))
                    .opacity(0)
                
                VStack {
                    Button(action: {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                        isRecording.toggle()
                    }) {
                        Text(isRecording ? "Stop" : "Record")
                            .font(.title)
                            .padding()
                            .background(isRecording ? Color.red : Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    
                    Button(action: {
                        transcribeRecording()
                    }) {
                        Text("Send")
                            .font(.title)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .disabled(!isRecording)
                    }
                    .padding(.top, 20)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showMailComposer) {
            MailComposer(audioFilename: audioFilename!, transcription: transcribedText)
                .onDisappear {
                    UserDefaults.standard.set(transcribedText, forKey: "TranscribedText")
                }
        }
        .onAppear {
            if let savedTranscribedText = UserDefaults.standard.string(forKey: "TranscribedText") {
                self.transcribedText = savedTranscribedText
            } else {
                self.transcribedText = ""
            }
        }
    }
    
    func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
            
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            audioFilename = documentsDirectory.appendingPathComponent("recording.wav")
            
            let settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ] as [String : Any]
            
            audioRecorder = try AVAudioRecorder(url: audioFilename!, settings: settings)
            audioRecorder?.record()
        } catch {
            print("Recording failed")
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
    }
    
    func transcribeRecording() {
        guard let audioFilename = audioFilename else {
            print("Audio file not found")
            return
        }
        
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        
        if recognizer?.isAvailable ?? false {
            let request = SFSpeechURLRecognitionRequest(url: audioFilename)
            recognizer?.recognitionTask(with: request) { [self] (result, error) in
                if let error = error {
                    print("Transcription error: \(error.localizedDescription)")
                } else {
                    var transcription = ""
                    if let result = result {
                        for segment in result.bestTranscription.segments {
                            transcription += segment.substring + " "
                        }
                        
                        transcription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("Transcription: \(transcription)")
                        
                        if result.isFinal {
                            DispatchQueue.main.async {
                                self.transcribedText = transcription
                                self.showMailComposer = true
                                sendTranscriptionToSlack(transcription: transcription, audioFileURL: audioFilename)
                            }
                        }
                    }
                    
            
                    UserDefaults.standard.set(self.transcribedText, forKey: "TranscribedText")
                }
            }
        } else {
            print("Speech recognition not available")
        }
    }
    
    func sendTranscriptionToSlack(transcription: String, audioFileURL: URL) {
        let slackAuthToken = "xoxb-33869562309-5304677261362-SJvssVdqbdIJULC6zfj5oITV"
        let channelID = "voice-messages"
        
        let url = "https://slack.com/api/files.upload"
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(slackAuthToken)"
        ]
        
        let parameters: Parameters = [
            "channels": channelID,
            "initial_comment": transcription
        ]
        
        AF.upload(
            multipartFormData: { multipartFormData in
                if let audioData = try? Data(contentsOf: audioFileURL) {
                    multipartFormData.append(audioData, withName: "file", fileName: "recording.wav", mimeType: "audio/wav")
                }
                
                for (key, value) in parameters {
                    if let data = "\(value)".data(using: .utf8) {
                        multipartFormData.append(data, withName: key)
                    }
                }
            },
            to: url,
            method: .post,
            headers: headers
        )
        .responseJSON { response in
            switch response.result {
            case .success(let value):
                print("Transcription and audio file sent to Slack: \(value)")
            case .failure(let error):
                print("Failed to send transcription and audio file to Slack: \(error)")
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
