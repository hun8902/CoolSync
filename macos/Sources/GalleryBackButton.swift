import SwiftUI

struct GalleryBackButton:View {
    var action:()->Void
    var body:some View {
        Button(action:action){
            HStack(spacing:8){Image(systemName:"chevron.left");Text("CoolSync");Spacer(minLength:0)}
                .padding(.horizontal,10).frame(maxWidth:.infinity,minHeight:40,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Text("CoolSync로 돌아가기")).help("CoolSync로 돌아가기")
    }
}
