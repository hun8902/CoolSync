import Foundation

extension GalleryModel {
    func galleryDidChange(){
        galleryDirty=true;event("phone gallery change event")
        _ = refreshAfterGalleryChange()
        if galleryVisible,category=="최근 삭제된 항목",unlocked{loadDeleted()}
    }
    @discardableResult func refreshAfterGalleryChange()->Bool {
        guard galleryDirty,galleryVisible,!loading else{return false}
        reload();return true
    }
    func closeRemovedPhoto(){
        selected=nil;original=nil;motion=nil;livePhoto=nil;editing=false;editAfterOpen=false;slideshow=false
    }
    func reconcileGallerySelection(){
        let ids=Set(items.map{$0.id});selection.formIntersection(ids)
        if let selected,!ids.contains(selected.id){closeRemovedPhoto()}
    }
    func finishLocalTrashChange(){
        // Reject every read started before the mutation response, then read current phone state.
        generation=UUID();transport.invalidate();loading=false;fetching=false;queue=[];waiting=[]
        pendingTrashPaths=[];photoTrashRunning=false;sync.phase = .ready
        saveCatalogCache();galleryDidChange()
    }
    func trashItems(_ values:[GalleryItem]){
        guard !values.isEmpty,!photoTrashRunning else{return}
        let token=librarySession,batches=PhotoBatches.paths(values.map{$0.path})
        photoTrashRunning=true;let paths=Set(values.map{$0.path})
        pendingTrashPaths.formUnion(paths);items.removeAll{paths.contains($0.path)}
        selection.subtract(values.map{$0.id});if let selected,paths.contains(selected.path){closeRemovedPhoto()}
        saveCatalogCache();status="휴지통으로 이동 중 · \(values.count)개"
        func step(_ index:Int){
            guard librarySession==token else{return}
            guard index<batches.count else{status="\(values.count)개 휴지통으로 이동됨";finishLocalTrashChange();return}
            let batch=Set(batches[index])
            explorer.call("trash",["paths":Array(batch)]){[weak self]response in
                guard let self,self.librarySession==token else{return}
                if response["ok"]as?Bool==true{step(index+1)}
                else{
                    let failed=Set(batches[index...].flatMap{$0});self.pendingTrashPaths.subtract(failed)
                    let present=Set(self.items.map{$0.id});self.items+=values.filter{failed.contains($0.path) && !present.contains($0.id)}
                    self.status=response["error"]as?String ?? "휴지통 이동 실패"
                    self.finishLocalTrashChange()
                }
            }
        }
        step(0)
    }
}
