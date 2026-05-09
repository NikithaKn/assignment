async function loadDashboard() {

  const response = await fetch('./data/releases.json');
  const data = await response.json();

  document.getElementById('releaseCount').innerText =
    data.totalReleases;

  document.getElementById('jiraCount').innerText =
    data.totalTickets;

  document.getElementById('commitCount').innerText =
    data.totalCommits;

  document.getElementById('successRate').innerText =
    data.successRate + '%';

  const table = document.getElementById('releaseTable');

  data.releases.forEach(release => {

    const row = `
      <tr>
        <td>${release.tag}</td>
        <td>${release.date}</td>
        <td>${release.tickets}</td>
        <td>
          <a href="${release.confluence}" target="_blank">
            Open
          </a>
        </td>
      </tr>
    `;

    table.innerHTML += row;
  });
}

loadDashboard();
