// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package progressview

import (
	"fmt"
	"strings"
	"sync"

	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"

	"github.com/open-edge-platform/image-composer-tool/cmd/live-installer/texture-ui/primitives/progressbar"
	"github.com/open-edge-platform/image-composer-tool/cmd/live-installer/texture-ui/uitext"
	"github.com/open-edge-platform/image-composer-tool/cmd/live-installer/texture-ui/uiutils"
	"github.com/open-edge-platform/image-composer-tool/internal/config"
	"github.com/open-edge-platform/image-composer-tool/internal/utils/logger"
)

// UI constants.
const (
	defaultPadding    = 1
	defaultProportion = 1
	defaultMoreDetail = false

	logTextHeight = 0
)

// ProgressView contains the Progress UI
type ProgressView struct {
	// UI elements
	app                 *tview.Application
	flex                *tview.Flex
	logText             *tview.TextView
	progressBar         *progressbar.ProgressBar
	centeredProgressBar *tview.Flex

	// Generate state
	alreadyShown bool
	moreDetails  bool

	// Callbacks
	performInstallation func(chan int, chan string)
	nextPage            func()
	quit                func()
}

var log = logger.Logger()

// New creates and returns a new ProgressView.
func New(performInstallation func(chan int, chan string)) *ProgressView {
	return &ProgressView{
		moreDetails:         defaultMoreDetail,
		performInstallation: performInstallation,
	}
}

// Initialize initializes the view.
func (pv *ProgressView) Initialize(backButtonText string, template *config.ImageTemplate, app *tview.Application, nextPage, previousPage, quit, refreshTitle func()) (err error) {
	pv.app = app
	pv.nextPage = nextPage
	pv.quit = quit

	pv.logText = tview.NewTextView().
		SetWordWrap(true).
		SetScrollable(false).
		SetDynamicColors(true).
		SetChangedFunc(func() {
			app.Draw()
		})

	pv.progressBar = progressbar.NewProgressBar().
		SetChangedFunc(func() {
			app.Draw()
		})

	pv.centeredProgressBar = uiutils.CenterVertically(pv.progressBar.GetHeight(), pv.progressBar)

	pv.flex = tview.NewFlex().SetDirection(tview.FlexRow)

	pv.switchDetailLevel(pv.moreDetails)

	// Box styling
	pv.logText.SetBorderPadding(defaultPadding, defaultPadding, defaultPadding, defaultPadding)

	pv.flex.SetBackgroundColor(tview.Styles.PrimitiveBackgroundColor)

	return
}

// HandleInput handles custom input.
func (pv *ProgressView) HandleInput(event *tcell.EventKey) *tcell.EventKey {
	switch event.Key() {
	// Prevent exiting the UI here as installation has already begun.
	case tcell.KeyCtrlC:
		return nil
	case tcell.KeyCtrlA:
		pv.switchDetailLevel(!pv.moreDetails)
	}

	return event
}

// Reset resets the page, undoing any user input.
func (pv *ProgressView) Reset() (err error) {
	return
}

// Name returns the friendly name of the view.
func (pv *ProgressView) Name() string {
	return "PROGRESS"
}

// Title returns the title of the view.
func (pv *ProgressView) Title() string {
	return uitext.ProgressTitle
}

// Primitive returns the primary primitive to be rendered for the view.
func (pv *ProgressView) Primitive() tview.Primitive {
	return pv.flex
}

// OnShow gets called when the view is shown to the user.
func (pv *ProgressView) OnShow() {
	if pv.alreadyShown {
		log.Panicf("ProgressView shown more than once, unsupported behavior.")
	}

	pv.alreadyShown = true

	go pv.startInstallation()
}

func (pv *ProgressView) switchDetailLevel(moreDetail bool) {
	pv.moreDetails = moreDetail

	if moreDetail {
		pv.flex.RemoveItem(pv.centeredProgressBar)
		pv.flex.AddItem(pv.logText, logTextHeight, defaultProportion, true)
	} else {
		pv.flex.RemoveItem(pv.logText)
		pv.flex.AddItem(pv.centeredProgressBar, 0, defaultProportion, true)
	}
}

func (pv *ProgressView) startInstallation() {
	progress := make(chan int)
	status := make(chan string)

	wg := new(sync.WaitGroup)
	wg.Add(2)

	go pv.monitorProgress(progress, wg)
	go pv.monitorStatus(status, wg)

	pv.performInstallation(progress, status)

	wg.Wait()

	// startInstallation runs on its own goroutine (see OnShow), so unlike
	// direct button-driven navigation, nextPage must be marshaled onto the
	// event-loop goroutine here.
	pv.app.QueueUpdateDraw(func() {
		pv.nextPage()
	})
}

func (pv *ProgressView) monitorProgress(progress chan int, wg *sync.WaitGroup) {
	for progressUpdate := range progress {
		pv.progressBar.SetProgress(progressUpdate)
	}

	wg.Done()
}

// monitorStatus updates the progress bar directly rather than through the
// progress channel: the installer closes that channel when it returns, which
// can happen while the last status line is still being processed here.
func (pv *ProgressView) monitorStatus(status chan string, wg *sync.WaitGroup) {
	for statusUpdate := range status {
		if strings.Contains(statusUpdate, "provider initialized") {
			pv.progressBar.SetProgress(10)
		} else if strings.Contains(statusUpdate, "merged user and default configurations") {
			pv.progressBar.SetProgress(20)
		} else if strings.Contains(statusUpdate, "Building image") {
			pv.progressBar.SetProgress(30)
		} else if strings.Contains(statusUpdate, "Creating partition") {
			pv.progressBar.SetProgress(40)
		} else if strings.Contains(statusUpdate, "Installing OS for image") {
			pv.progressBar.SetProgress(50)
		} else if strings.Contains(statusUpdate, "Image system configuration") {
			pv.progressBar.SetProgress(70)
		} else if strings.Contains(statusUpdate, "Installing bootloader") {
			pv.progressBar.SetProgress(80)
		} else if strings.Contains(statusUpdate, "Image installation post-processing") {
			pv.progressBar.SetProgress(90)
		} else if strings.Contains(statusUpdate, "OS installation completed") {
			pv.progressBar.SetProgress(100)
		}
		pv.progressBar.SetStatus(statusUpdate)
		fmt.Fprintf(pv.logText, "%s", statusUpdate)
	}

	wg.Done()
}
