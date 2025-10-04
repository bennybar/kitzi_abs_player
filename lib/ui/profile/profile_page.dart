import 'package:flutter/material.dart';
import 'dart:convert';
import '../../main.dart'; // ServicesScope
import '../../core/auth_repository.dart';
import '../../core/books_repository.dart';
import '../../models/book.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  Map<String, dynamic>? _profileData;
  bool _isLoading = true;
  String? _error;
  final Map<String, String> _bookNames = {}; // Cache for book names

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_profileData == null && _error == null) {
      _loadProfileData();
    }
  }

  Future<void> _loadProfileData() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final services = ServicesScope.of(context).services;
      final api = services.auth.api;
      
      final response = await api.request('GET', '/api/me', auth: true);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        debugPrint('Profile data keys: ${data.keys.toList()}');
        if (data['mediaProgress'] != null) {
          debugPrint('MediaProgress type: ${data['mediaProgress'].runtimeType}');
          if (data['mediaProgress'] is List) {
            final progressList = data['mediaProgress'] as List;
            debugPrint('MediaProgress length: ${progressList.length}');
            if (progressList.isNotEmpty) {
              debugPrint('First progress item: ${progressList.first}');
              debugPrint('First progress item keys: ${(progressList.first as Map).keys.toList()}');
              final firstItem = progressList.first as Map<String, dynamic>;
              debugPrint('First item currentTime: ${firstItem['currentTime']}');
              debugPrint('First item duration: ${firstItem['duration']}');
              debugPrint('First item progress: ${firstItem['progress']}');
            }
          }
        }
        setState(() {
          _profileData = data;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load profile data (${response.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error loading profile: $e';
        _isLoading = false;
      });
    }
  }

  Widget _buildProfileCard() {
    if (_isLoading) {
      return const Card(
        margin: EdgeInsets.all(16),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    if (_error != null) {
      return Card(
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Failed to load profile',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadProfileData,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_profileData == null) {
      return const Card(
        margin: EdgeInsets.all(16),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text('No profile data available'),
          ),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with user icon
            Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Icon(
                    Icons.person,
                    size: 32,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _profileData!['username'] ?? 'Unknown User',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_profileData!['email'] != null)
                        Text(
                          _profileData!['email'],
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 24),
            
            // Profile details
            _buildDetailRow('User ID', _profileData!['id']?.toString() ?? 'N/A'),
            _buildDetailRow('Username', _profileData!['username'] ?? 'N/A'),
            if (_profileData!['email'] != null)
              _buildDetailRow('Email', _profileData!['email']),
            if (_profileData!['firstName'] != null)
              _buildDetailRow('First Name', _profileData!['firstName']),
            if (_profileData!['lastName'] != null)
              _buildDetailRow('Last Name', _profileData!['lastName']),
            if (_profileData!['isActive'] != null)
              _buildDetailRow('Status', _profileData!['isActive'] ? 'Active' : 'Inactive'),
            if (_profileData!['isLocked'] != null)
              _buildDetailRow('Account Locked', _profileData!['isLocked'] ? 'Yes' : 'No'),
            if (_profileData!['lastSeen'] != null)
              _buildDetailRow('Last Seen', _formatDate(_profileData!['lastSeen'])),
            if (_profileData!['createdAt'] != null)
              _buildDetailRow('Member Since', _formatDate(_profileData!['createdAt'])),
            
            // Server information
            const SizedBox(height: 16),
            Divider(color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'Server Information',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _buildDetailRow('Server URL', _getServerUrl()),
            _buildDetailRow('Token Expiry', _getTokenExpiry()),
            
            // Statistics section
            const SizedBox(height: 16),
            Divider(color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'Statistics',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _buildDetailRow('Books in Progress', _getBooksInProgress()),
            _buildDetailRow('Total Books', _getTotalBooks()),
            _buildDetailRow('Total Listening Time', _getTotalListeningTime()),
            
            // Recent Activity section
            const SizedBox(height: 16),
            Divider(color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'Recent Activity',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _buildRecentActivity(),
            
            const SizedBox(height: 16),
            
            // Refresh button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _loadProfileData,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh Profile'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(dynamic dateValue) {
    if (dateValue == null) return 'N/A';
    
    try {
      // Handle different date formats
      String dateStr = dateValue.toString();
      DateTime date;
      
      if (dateStr.contains('T')) {
        // ISO format
        date = DateTime.parse(dateStr);
      } else if (dateStr.contains('-')) {
        // Date only format
        date = DateTime.parse(dateStr);
      } else {
        // Unix timestamp
        date = DateTime.fromMillisecondsSinceEpoch(int.parse(dateStr));
      }
      
      return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return dateValue.toString();
    }
  }

  String _getServerUrl() {
    try {
      final services = ServicesScope.of(context).services;
      final baseUrl = services.auth.api.baseUrl;
      return baseUrl ?? 'N/A';
    } catch (e) {
      return 'N/A';
    }
  }

  String _getTokenExpiry() {
    try {
      final services = ServicesScope.of(context).services;
      final expiry = services.auth.api.accessTokenExpiry();
      if (expiry == null) return 'N/A';
      
      final now = DateTime.now().toUtc();
      final difference = expiry.difference(now);
      
      if (difference.isNegative) {
        return 'Expired';
      } else if (difference.inDays > 0) {
        return '${difference.inDays} days remaining';
      } else if (difference.inHours > 0) {
        return '${difference.inHours} hours remaining';
      } else {
        return '${difference.inMinutes} minutes remaining';
      }
    } catch (e) {
      return 'N/A';
    }
  }

  Future<String> _getBookName(String libraryItemId) async {
    if (_bookNames.containsKey(libraryItemId)) {
      return _bookNames[libraryItemId]!;
    }

    try {
      final repo = await BooksRepository.create();
      final book = await repo.getBook(libraryItemId);
      final name = book.title;
      _bookNames[libraryItemId] = name;
      return name;
    } catch (e) {
      debugPrint('Failed to fetch book name for $libraryItemId: $e');
      return 'Unknown Book';
    }
  }

  String _getBooksInProgress() {
    try {
      final mediaProgress = _profileData!['mediaProgress'];
      if (mediaProgress == null) return '0';
      
      int inProgress = 0;
      if (mediaProgress is List<dynamic>) {
        for (final item in mediaProgress) {
          if (item is Map<String, dynamic>) {
            final progress = item['progress'] as num?;
            if (progress != null && progress > 0 && progress < 1) {
              inProgress++;
            }
          }
        }
      }
      
      return inProgress.toString();
    } catch (e) {
      debugPrint('Error in _getBooksInProgress: $e');
      return 'N/A';
    }
  }

  String _getTotalBooks() {
    try {
      final mediaProgress = _profileData!['mediaProgress'];
      if (mediaProgress == null) return '0';
      
      if (mediaProgress is List<dynamic>) {
        return mediaProgress.length.toString();
      }
      
      return '0';
    } catch (e) {
      debugPrint('Error in _getTotalBooks: $e');
      return 'N/A';
    }
  }

  String _getTotalListeningTime() {
    try {
      final mediaProgress = _profileData!['mediaProgress'];
      if (mediaProgress == null) return '0 hours';
      
      int totalSeconds = 0;
      if (mediaProgress is List<dynamic>) {
        for (final item in mediaProgress) {
          if (item is Map<String, dynamic>) {
            final currentTime = item['currentTime'] as num?;
            if (currentTime != null) {
              totalSeconds += currentTime.toInt();
            }
          }
        }
      }
      
      final hours = totalSeconds ~/ 3600;
      final minutes = (totalSeconds % 3600) ~/ 60;
      
      if (hours > 0) {
        return '${hours}h ${minutes}m';
      } else {
        return '${minutes}m';
      }
    } catch (e) {
      debugPrint('Error in _getTotalListeningTime: $e');
      return 'N/A';
    }
  }

  Widget _buildRecentActivity() {
    try {
      final mediaProgress = _profileData!['mediaProgress'];
      if (mediaProgress == null || !(mediaProgress is List<dynamic>) || mediaProgress.isEmpty) {
        return Text(
          'No recent activity',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        );
      }

      // Get the 3 most recently updated items
      final items = mediaProgress.cast<Map<String, dynamic>>();
      items.sort((a, b) {
        final aLastUpdate = a['lastUpdate'] as num? ?? 0;
        final bLastUpdate = b['lastUpdate'] as num? ?? 0;
        return bLastUpdate.compareTo(aLastUpdate);
      });

      final recentItems = items.take(3).toList();
      
      return Column(
        children: recentItems.map((item) {
          try {
            final libraryItemId = item['libraryItemId'] as String? ?? 'Unknown';
            final lastUpdate = item['lastUpdate'] as num?;
            
            // Calculate progress percentage using the same logic as the app
            double progressPercent = 0.0;
            final currentTime = item['currentTime'] as num? ?? 0;
            final duration = item['duration'] as num? ?? 0;
            
            debugPrint('Progress calculation for $libraryItemId: currentTime=$currentTime, duration=$duration');
            
            if (duration > 0) {
              progressPercent = (currentTime / duration) * 100;
              debugPrint('Calculated progress: ${progressPercent.toStringAsFixed(1)}%');
            } else {
              // Fallback to progress field if duration is not available
              final progress = item['progress'] as num?;
              if (progress != null) {
                progressPercent = progress * 100;
                debugPrint('Using progress field: ${progressPercent.toStringAsFixed(1)}%');
              }
            }
            
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FutureBuilder<String>(
                            future: _getBookName(libraryItemId),
                            builder: (context, snapshot) {
                              final bookName = snapshot.data ?? 'Loading...';
                              return Text(
                                bookName,
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              );
                            },
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Progress: ${progressPercent.toStringAsFixed(1)}%',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (lastUpdate != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Last updated: ${_formatDate(DateTime.fromMillisecondsSinceEpoch(lastUpdate.toInt()))}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    CircularProgressIndicator(
                      value: progressPercent / 100,
                      strokeWidth: 3,
                    ),
                  ],
                ),
              ),
            );
          } catch (e) {
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Error loading item: $e',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            );
          }
        }).toList(),
      );
    } catch (e) {
      return Text(
        'Error loading recent activity: $e',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            onPressed: _loadProfileData,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Profile',
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: _buildProfileCard(),
      ),
    );
  }
}
