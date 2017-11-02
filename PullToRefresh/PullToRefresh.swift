//
//  Created by Anastasiya Gorban on 4/14/15.
//  Copyright (c) 2015 Yalantis. All rights reserved.
//
//  Licensed under the MIT license: http://opensource.org/licenses/MIT
//  Latest version can be found at https://github.com/Yalantis/PullToRefresh
//

import UIKit

public enum Position {
    
    case top, bottom
}

open class PullToRefresh: NSObject {
    
    open var position: Position = .top
    
    open var animationDuration: TimeInterval = 1
    open var hideDelay: TimeInterval = 0
    open var springDamping: CGFloat = 0.4
    open var initialSpringVelocity: CGFloat = 0.8
    open var animationOptions: UIViewAnimationOptions = [.curveLinear]

    let refreshView: UIView
    var action: (() -> ())?
    
    weak var scrollView: UIScrollView? {
        willSet {
            if #available(iOS 11.0, *) {
                scrollView?.removeAdjustedContentInsetsHandler(forPosition: position)
            } 
            removeScrollViewObserving()
        }
        didSet {
            if let scrollView = scrollView {
                if #available(iOS 11.0, *) {
                    scrollView.addAdjustedContentInsetsHandler(forPosition: position) { [weak self] (adjustedInsets) in
                        self?.scrollViewDefaultAdjustedInsets = adjustedInsets
                    }
                }
                scrollViewDefaultInsets = scrollView.contentInset
                addScrollViewObserving()
            }
        }
    }
    
    fileprivate let animator: RefreshViewAnimator
    fileprivate var isObserving = false
    
    // MARK: - ScrollView & Observing
    
    fileprivate var scrollViewDefaultInsets: UIEdgeInsets = .zero
    fileprivate var scrollViewDefaultAdjustedInsets: UIEdgeInsets = .zero
    fileprivate var previousScrollViewOffset: CGPoint = CGPoint.zero
    
    // MARK: - State

    open fileprivate(set) var state: State = .initial {
        didSet {
            animator.animate(state)
            switch state {
            case .loading:
                if oldValue != .loading {
                    animateLoadingState()
                }
                
            case .finished:
                if isCurrentlyVisible {
                    animateFinishedState()
                } else {
                    scrollView?.contentInset = self.scrollViewDefaultInsets
                    state = .initial
                }
        
            default: break
            }
        }
    }
    
    // MARK: - Initialization
    
    public init(refreshView: UIView, animator: RefreshViewAnimator, height: CGFloat, position: Position) {
        self.refreshView = refreshView
        self.animator = animator
        self.position = position
    }
    
    public convenience init(height: CGFloat = 40, position: Position = .top) {
        let refreshView = DefaultRefreshView()
        refreshView.translatesAutoresizingMaskIntoConstraints = false
        refreshView.autoresizingMask = [.flexibleWidth]
        refreshView.frame.size.height = height
        self.init(refreshView: refreshView, animator: DefaultViewAnimator(refreshView: refreshView), height: height, position: position)
    }
    
    deinit {
        scrollView?.removePullToRefresh(at: position)
        removeScrollViewObserving()
    }
}

// MARK: KVO
extension PullToRefresh {
    
    fileprivate struct KVO {
        
        static var context = "PullToRefreshKVOContext"
        
        enum ScrollViewPath {
            static let contentOffset = #keyPath(UIScrollView.contentOffset)
            static let contentInset = #keyPath(UIScrollView.contentInset)
            static let contentSize = #keyPath(UIScrollView.contentSize)
        }
        
    }
    
    override open func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if (context == &KVO.context && keyPath == KVO.ScrollViewPath.contentOffset && object as? UIScrollView == scrollView) {
            var offset: CGFloat
            switch position {
            case .top:
                offset = previousScrollViewOffset.y + defaultInsets.top
                
            case .bottom:
                if scrollView!.contentSize.height > scrollView!.bounds.height {
                    offset = scrollView!.contentSize.height - previousScrollViewOffset.y - scrollView!.bounds.height
                } else {
                    offset = scrollView!.contentSize.height - previousScrollViewOffset.y
                }
            }
            let refreshViewHeight = refreshView.frame.size.height
            
            switch offset {
            case 0 where (state != .loading): state = .initial
            case -refreshViewHeight...0 where (state != .loading && state != .finished):
                state = .releasing(progress: -offset / refreshViewHeight)
                
            case -1000...(-refreshViewHeight):
                if state == .releasing(progress: 1) && scrollView?.isDragging == false {
                    state = .loading
                } else if state != .loading && state != .finished {
                    state = .releasing(progress: 1)
                }
            default: break
            }
        } else if (context == &KVO.context && keyPath == KVO.ScrollViewPath.contentSize && object as? UIScrollView == scrollView) {
            if case .bottom = position {
                refreshView.frame = CGRect(x: 0, y: scrollView!.contentSize.height, width: scrollView!.bounds.width, height: refreshView.bounds.height)
            }
        } else if (context == &KVO.context && keyPath == KVO.ScrollViewPath.contentInset && object as? UIScrollView == scrollView) {
            if self.state == .initial {
                scrollViewDefaultInsets = scrollView!.contentInset
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
        previousScrollViewOffset.y = scrollView?.contentOffset.y ?? 0
    }
    
    fileprivate func addScrollViewObserving() {
        guard let scrollView = scrollView, !isObserving else {
            return
        }
        
        scrollView.addObserver(self, forKeyPath: KVO.ScrollViewPath.contentOffset, options: .initial, context: &KVO.context)
        scrollView.addObserver(self, forKeyPath: KVO.ScrollViewPath.contentSize, options: .initial, context: &KVO.context)
        scrollView.addObserver(self, forKeyPath: KVO.ScrollViewPath.contentInset, options: .new, context: &KVO.context)
        
        isObserving = true
    }
    
    fileprivate func removeScrollViewObserving() {
        guard let scrollView = scrollView, isObserving else {
            return
        }
        
        scrollView.removeObserver(self, forKeyPath: KVO.ScrollViewPath.contentOffset, context: &KVO.context)
        scrollView.removeObserver(self, forKeyPath: KVO.ScrollViewPath.contentSize, context: &KVO.context)
        scrollView.removeObserver(self, forKeyPath: KVO.ScrollViewPath.contentInset, context: &KVO.context)
        
        isObserving = false
    }
    
}

// MARK: - Start/End Refreshin
extension PullToRefresh {
    
    func startRefreshing() {
        if self.state != .initial {
            return
        }
        
        var offsetY: CGFloat
        switch position {
        case .top:
            offsetY = -refreshView.frame.height - scrollViewDefaultInsets.top
            
        case .bottom:
            offsetY = scrollView!.contentSize.height + refreshView.frame.height + scrollViewDefaultInsets.bottom - scrollView!.bounds.height
        }
        
        scrollView?.setContentOffset(CGPoint(x: 0, y: offsetY), animated: true)
        let delayTime = DispatchTime.now() + Double(Int64(0.27 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
        DispatchQueue.main.asyncAfter(deadline: delayTime) { [weak self] in
            self?.state = .loading
        }
    }
    
    func endRefreshing() {
        if state == .loading {
            state = .finished
        }
    }
}

// MARK: - Animate scroll view
private extension PullToRefresh {
    
    func animateLoadingState() {
        guard let scrollView = scrollView else {
            return
        }
        
        scrollView.contentOffset = previousScrollViewOffset
        scrollView.bounces = false
        UIView.animate(
            withDuration: 0.3,
            animations: {
                switch self.position {
                case .top:
                    let insets = self.refreshView.frame.height + self.scrollViewDefaultInsets.top
                    scrollView.contentInset.top = insets
                    scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: -insets)
                    
                case .bottom:
                    let insets = self.refreshView.frame.height + self.scrollViewDefaultInsets.bottom
                    scrollView.contentInset.bottom = insets
                }
            },
            completion: { _ in
                scrollView.bounces = true
            }
        )
        
        action?()
    }
    
    func animateFinishedState() {
        removeScrollViewObserving()
        UIView.animate(
            withDuration: animationDuration,
            delay: hideDelay,
            usingSpringWithDamping: springDamping,
            initialSpringVelocity: initialSpringVelocity,
            options: animationOptions,
            animations: {
                self.scrollView?.contentInset = self.scrollViewDefaultInsets
                if case .top = self.position {
                    self.scrollView?.contentOffset.y = -self.defaultInsets.top
                }
            },
            completion: { _ in
                self.addScrollViewObserving()
                self.state = .initial
            }
        )
    }
}

// MARK: - Helpers
private extension PullToRefresh {
    
    var defaultInsets: UIEdgeInsets {
        if #available(iOS 11, *) {
            return scrollViewDefaultAdjustedInsets
        } else {
            return scrollViewDefaultInsets
        }
    }
    
    var isCurrentlyVisible: Bool {
        guard let scrollView = scrollView else { return false }
        
        return scrollView.contentOffset.y <= -defaultInsets.top
    }
}
