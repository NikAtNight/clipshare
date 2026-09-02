const player = document.querySelector("video");
const message = document.querySelector("#playback-error");

player?.addEventListener("contextmenu", (event) => {
  event.preventDefault();
});

player?.addEventListener("error", () => {
  player.hidden = true;
  message.hidden = false;
});
