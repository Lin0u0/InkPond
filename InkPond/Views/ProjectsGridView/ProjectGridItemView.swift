import SwiftUI

/// A view that shows a single landmark in a grid.
struct ProjectGridItemView: View {
    let project: InkPondProject

    var body: some View {
        Color.blue
//        Image(project.thumbnailImageName)
//            .resizable()
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                Rectangle()
                    .foregroundStyle(.clear)
                    .background(
                        LinearGradient(colors: [.black, .clear], startPoint: .bottom, endPoint: .center)
                    )
                    .containerRelativeFrame(.vertical)
                    .clipped()
            }
            .clipped()
            .cornerRadius(15.0)
            .overlay(alignment: .bottom) {
                Text(project.title)
                    .font(.title3)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.white)
                    .padding(.bottom)
            }
    }
}

