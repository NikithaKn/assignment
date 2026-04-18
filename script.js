fetch('data.json')
  .then(res => res.json())
  .then(data => {

    document.getElementById('releases').innerText = data.total_releases;
    document.getElementById('commits').innerText = data.total_commits;

    new Chart(document.getElementById('releaseChart'), {
      type: 'bar',
      data: {
        labels: data.release_names,
        datasets: [{
          label: 'Releases',
          data: data.release_counts
        }]
      }
    });

  });