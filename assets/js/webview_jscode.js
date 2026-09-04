var videoEl = null;

function delay(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

function setscale(scaletype) {
    if (!videoEl) return;

    let objectFitValue = 'contain';
    let aspectratioValue = 'auto';
    let widthValue = '100%';
    let heightValue = '100%';

    switch (scaletype) {
        case 0:
            objectFitValue = 'contain';
            aspectratioValue = 'auto';
            widthValue = '100%';
            break;
        case 1:
            objectFitValue = 'contain';
            aspectratioValue = '16/9';
            widthValue = '100%';
            break;
        case 2:
            aspectratioValue = '4/3';
            objectFitValue = 'fill';
            widthValue = 'auto';
            break;
        case 3:
            objectFitValue = 'fill';
            aspectratioValue = 'none';
            widthValue = '100%';
            break;
        case 4:
            objectFitValue = 'contain';
            aspectratioValue = 'auto';
            widthValue = '100%';
            break;
        case 5:
            objectFitValue = 'cover';
            aspectratioValue = 'none';
            widthValue = '100%';
            break;
        case 6:
            objectFitValue = 'fill';
            aspectratioValue = 'auto';
            widthValue = '100%';
            const screenWidth = window.innerWidth;
            const screenHeight = window.innerHeight;
            let videoHeight = screenWidth / 2.35;
            if (videoHeight > screenHeight) {
                videoHeight = screenHeight;
            }
            heightValue = (videoHeight / screenHeight) * 100 + '%';
            break;
    }

    videoEl.style.cssText = `
        width: ${widthValue} !important;
        height: ${heightValue} !important;
        object-fit: ${objectFitValue} !important;
        aspect-ratio: ${aspectratioValue} !important;
        position: absolute !important;
        top: 50% !important;
        left: 50% !important;
        transform: translate(-50%, -50%) !important;
    `;
}

function play() {
    if (videoEl && videoEl.paused) videoEl.play().catch(e => console.warn('play failed:', e));
}

function pause() {
    if (videoEl && !videoEl.paused) videoEl.pause();
}

function setposition(position) {
    if (videoEl) videoEl.currentTime = position;
}

function setspeed(speed) {
    if (videoEl) videoEl.playbackRate = speed;
}

(async function() {
    while (true) {
        videoEl = document.querySelector('video');
        if (videoEl && videoEl.readyState >= 1) {
            break;
        }
        await delay(50);
    }

    document.body.style.cssText = 'width: 100vw; height: 100vh; margin: 0; min-width: 0; background: #000000; overflow: hidden;';
    document.documentElement.style.overflow = 'hidden';

    let fullscreenContainer = document.createElement('div');
    fullscreenContainer.style.cssText = `
        position: fixed !important;
        top: 0 !important;
        left: 0 !important;
        width: 100% !important;
        height: 100% !important;
        z-index: 999999 !important;
        background: black !important;
        overflow: hidden !important;
    `;
    document.body.appendChild(fullscreenContainer);

    if (videoEl.parentNode !== fullscreenContainer) {
        fullscreenContainer.appendChild(videoEl);
    }

    videoEl.controls = false;
    videoEl.removeAttribute('controls');

    setTimeout(() => {
        if (videoEl) {
            if (videoEl.muted || videoEl.volume === 0) {
                videoEl.muted = false;
                videoEl.volume = 1;
            }
            if (videoEl.paused) {
                videoEl.play().catch(e => console.warn('play failed:', e));
            }
        }
    }, 300);

    if (videoEl.readyState < 1) {
        await new Promise(resolve => {
            videoEl.addEventListener('loadedmetadata', resolve, { once: true });
        });
    }

    if (typeof ku9 !== 'undefined' && ku9.getscale) {
        setscale(ku9.getscale());
    }

    if (typeof ku9 !== 'undefined' && ku9.setduration) {
        if (videoEl.duration > 0) {
            ku9.setduration(videoEl.duration);
        } else {
            videoEl.addEventListener('loadedmetadata', () => {
                if (videoEl.duration > 0) ku9.setduration(videoEl.duration);
            });
        }
    }

    if (typeof ku9 !== 'undefined' && ku9.setvideo) {
        if (videoEl.videoWidth && videoEl.videoHeight) {
            ku9.setvideo(videoEl.videoWidth, videoEl.videoHeight);
        } else {
            videoEl.addEventListener('loadedmetadata', () => {
                ku9.setvideo(videoEl.videoWidth, videoEl.videoHeight);
            });
        }
    }

    if (typeof ku9 !== 'undefined' && ku9.setposition) {
        videoEl.addEventListener('timeupdate', () => {
            ku9.setposition(videoEl.currentTime);
        });
    }

    videoEl.addEventListener('resize', () => {
        if (typeof ku9 !== 'undefined' && ku9.setvideo) {
            ku9.setvideo(videoEl.videoWidth, videoEl.videoHeight);
        }
        if (typeof ku9 !== 'undefined' && ku9.getscale) {
            setscale(ku9.getscale());
        }
    });
})();