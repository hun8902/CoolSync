import AppKit

/// Collection layout owns the cell size; decoded image dimensions never resize it.
final class PhotoThumbnailView:NSImageView{
    override var intrinsicContentSize:NSSize{NSSize(width:NSView.noIntrinsicMetric,height:NSView.noIntrinsicMetric)}
}

final class PhotoTile:NSCollectionViewItem {
    let badge=NSTextField(labelWithString:"")
    override func loadView(){let box=NSView(frame:NSRect(x:0,y:0,width:150,height:150));box.wantsLayer=true;box.layer?.cornerRadius=7;box.layer?.masksToBounds=true;view=box;let image=PhotoThumbnailView();image.wantsLayer=true;image.layer?.masksToBounds=true;image.setContentCompressionResistancePriority(.init(1),for:.horizontal);image.setContentCompressionResistancePriority(.init(1),for:.vertical);image.setContentHuggingPriority(.init(1),for:.horizontal);image.setContentHuggingPriority(.init(1),for:.vertical);image.imageScaling = .scaleProportionallyUpOrDown;image.translatesAutoresizingMaskIntoConstraints=false;box.addSubview(image);imageView=image;badge.translatesAutoresizingMaskIntoConstraints=false;badge.font = .monospacedDigitSystemFont(ofSize:11,weight:.semibold);badge.textColor = .white;badge.backgroundColor=NSColor.black.withAlphaComponent(0.55);badge.drawsBackground=true;box.addSubview(badge);NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:box.leadingAnchor,constant:4),image.trailingAnchor.constraint(equalTo:box.trailingAnchor,constant:-4),image.topAnchor.constraint(equalTo:box.topAnchor,constant:4),image.bottomAnchor.constraint(equalTo:box.bottomAnchor,constant:-4),badge.trailingAnchor.constraint(equalTo:box.trailingAnchor,constant:-9),badge.bottomAnchor.constraint(equalTo:box.bottomAnchor,constant:-8)])}
    override func prepareForReuse(){super.prepareForReuse();representedObject=nil;imageView?.image=nil;badge.stringValue="";badge.isHidden=true;view.layer?.borderWidth=0;view.layer?.backgroundColor=NSColor.clear.cgColor}
    override var isSelected:Bool{didSet{view.layer?.borderWidth=isSelected ? 3:0;view.layer?.borderColor=NSColor.controlAccentColor.cgColor;view.layer?.backgroundColor=isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor:NSColor.clear.cgColor}}
}
