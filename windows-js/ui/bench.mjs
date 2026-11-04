const status = document.getElementById("status");
for (const button of document.querySelectorAll("button"))
  button.onclick = async () => {
    const result = await window.gpt.command(
      button.dataset.command,
      button.dataset.value === undefined
        ? undefined
        : button.dataset.value === "true",
    );
    if (!result.ok) status.textContent = result.error;
    else await update();
  };
let count = 0;
document.getElementById("surface").onclick = () => {
  document.getElementById("count").textContent = "背景点击：" + ++count;
};
async function update() {
  const result = await window.gpt.command("bench-status");
  if (result.ok) {
    const { musicStatus, ...data } = result.data;
    status.textContent = JSON.stringify(
      { ...data, music: result.data.music, physics: musicStatus?.motion },
      null,
      2,
    );
  }
}
setInterval(update, 1000);
await update();
